import sys
sys.path.insert(0, srcdir('../..'))
import os
from textwrap import dedent
import yaml
import tempfile
import pandas as pd
from lcdblib.snakemake import helpers, aligners
from lcdblib.utils import utils
from lib import common, chipseq
from lib.patterns_targets import ChIPSeqConfig

# ----------------------------------------------------------------------------
# Note:
#
#  Search this file for the string "# TEST SETTINGS" and make necessary edits
#  before running this on real data.
# ----------------------------------------------------------------------------

include: '../references/references.snakefile'

shell.prefix('set -euo pipefail; export TMPDIR={};'.format(common.tempdir_for_biowulf()))
shell.executable('/bin/bash')

c = ChIPSeqConfig(config)


def wrapper_for(path):
    return 'file:' + os.path.join('../..','wrappers', 'wrappers', path)


# ----------------------------------------------------------------------------
# RULES
# ----------------------------------------------------------------------------

rule targets:
    """
    Final c.targets to create
    """
    input:
        (
            c.targets['bam'] +
            utils.flatten(c.targets['fastqc']) +
            utils.flatten(c.targets['libsizes']) +
            [c.targets['fastq_screen']] +
            [c.targets['libsizes_table']] +
            [c.targets['multiqc']] +
            utils.flatten(c.targets['markduplicates']) +
            utils.flatten(c.targets['bigwig']) +
            utils.flatten(c.targets['peaks']) +
            utils.flatten(c.targets['merged_techreps']) +
            utils.flatten(c.targets['fingerprint'])
        )


if 'orig_filename' in c.sampletable.columns:
    rule symlinks:
        """
        Symlinks files over from original filename
        """
        input: lambda wc: c.sampletable.set_index(c.sampletable.columns[0])['orig_filename'].to_dict()[wc.sample]
        output: c.patterns['fastq']
        run:
            utils.make_relative_symlink(input[0], output[0])

    rule symlink_targets:
        input: c.targets['fastq']


rule cutadapt:
    """
    Run cutadapt
    """
    input:
        fastq=c.patterns['fastq']
    output:
        fastq=c.patterns['cutadapt']
    log:
        c.patterns['cutadapt'] + '.log'
    params:
        extra='-a file:../../include/adapters.fa -q 20 --minimum-length=25'
    wrapper:
        wrapper_for('cutadapt')


rule fastqc:
    """
    Run FastQC
    """
    input: '{sample_dir}/{sample}/{sample}{suffix}'
    output:
        html='{sample_dir}/{sample}/fastqc/{sample}{suffix}_fastqc.html',
        zip='{sample_dir}/{sample}/fastqc/{sample}{suffix}_fastqc.zip',
    wrapper:
        wrapper_for('fastqc')


rule bowtie2:
    """
    Map reads with Bowtie2
    """
    input:
        fastq=rules.cutadapt.output.fastq,
        index=[refdict[c.assembly][config['aligner']['tag']]['bowtie2']]
    output:
        bam=c.patterns['bam']
    log:
        c.patterns['bam'] + '.log'
    params:
        samtools_view_extra='-F 0x04'
    threads: 6
    wrapper:
        wrapper_for('bowtie2/align')


rule unique:
    """
    Remove multimappers
    """
    input:
        c.patterns['bam']
    output:
        c.patterns['unique']
    params:
        extra="-b -q 20"
    shell:
        'samtools view -b -q 20 {input} > {output}'


rule fastq_count:
    """
    Count reads in a FASTQ file
    """
    input:
        fastq='{sample_dir}/{sample}/{sample}{suffix}.fastq.gz'
    output:
        count='{sample_dir}/{sample}/{sample}{suffix}.fastq.gz.libsize'
    shell:
        'zcat {input} | echo $((`wc -l`/4)) > {output}'


rule bam_count:
    """
    Count reads in a BAM file
    """
    input:
        bam='{sample_dir}/{sample}/{sample}{suffix}.bam'
    output:
        count='{sample_dir}/{sample}/{sample}{suffix}.bam.libsize'
    shell:
        'samtools view -c {input} > {output}'


rule bam_index:
    """
    Index a BAM
    """
    input:
        bam='{prefix}.bam'
    output:
        bai='{prefix}.bam.bai'
    shell:
        'samtools index {input} {output}'


rule fastq_screen:
    """
    Run fastq_screen to look for contamination from other genomes
    """
    input:
        fastq=rules.cutadapt.output.fastq,
        dm6=refdict[c.assembly][config['aligner']['tag']]['bowtie2'],
        phix=refdict['phix']['default']['bowtie2']
    output:
        txt=c.patterns['fastq_screen']
    log:
        c.patterns['fastq_screen'] + '.log'
    params:
        subset=100000
    wrapper:
        wrapper_for('fastq_screen')


rule libsizes_table:
    """
    Aggregate fastq and bam counts in to a single table
    """
    input:
        utils.flatten(c.targets['libsizes'])
    output:
        json=c.patterns['libsizes_yaml'],
        tsv=c.patterns['libsizes_table']
    run:
        def sample(f):
            return os.path.basename(os.path.dirname(f))

        def million(f):
            return float(open(f).read()) / 1e6

        def stage(f):
            return os.path.basename(f).split('.', 1)[1].replace('.gz', '').replace('.count', '')

        df = pd.DataFrame(dict(filename=list(map(str, input))))
        df['sample'] = df.filename.apply(sample)
        df['million'] = df.filename.apply(million)
        df['stage'] = df.filename.apply(stage)
        df = df.set_index('filename')
        df = df.pivot('sample', columns='stage', values='million')
        df.to_csv(output.tsv, sep='\t')
        y = {
            'id': 'libsizes_table',
            'section_name': 'Library sizes',
            'description': 'Library sizes at various stages of the pipeline',
            'plot_type': 'table',
            'pconfig': {
                'id': 'libsizes_table_table',
                'title': 'Library size table',
                'min': 0
            },
            'data': yaml.load(df.transpose().to_json()),
        }
        with open(output.json, 'w') as fout:
            yaml.dump(y, fout, default_flow_style=False)


rule multiqc:
    """
    Aggregate various QC stats and logs into a single HTML report with MultiQC
    """
    input:
        files=(
            utils.flatten(c.targets['fastqc']) +
            utils.flatten(c.targets['libsizes_yaml']) +
            utils.flatten(c.targets['cutadapt']) +
            utils.flatten(c.targets['bam']) +
            utils.flatten(c.targets['markduplicates']) +
            utils.flatten(c.targets['fastq_screen'])
        ),
        config='config/multiqc_config.yaml'
    output:
        c.targets['multiqc']
    params:
        analysis_directory=" ".join([c.sample_dir, c.agg_dir]),
        extra='--config config/multiqc_config.yaml',
        outdir=os.path.dirname(c.targets['multiqc'][0]),
        basename=os.path.basename(c.targets['multiqc'][0])
    log:
        c.targets['multiqc'][0] + '.log'
    shell:
        'LC_ALL=en_US.UTF.8 LC_LANG=en_US.UTF-8 '
        'multiqc '
        '--quiet '
        '--outdir {params.outdir} '
        '--force '
        '--filename {params.basename} '
        '--config config/multiqc_config.yaml '
        '{params.analysis_directory} '
        '&> {log} '


rule markduplicates:
    """
    Mark or remove PCR duplicates with Picard MarkDuplicates
    """
    input:
        bam=rules.bowtie2.output
    output:
        bam=c.patterns['markduplicates']['bam'],
        metrics=c.patterns['markduplicates']['metrics']
    log:
        c.patterns['markduplicates']['bam'] + '.log'
    params:
        # TEST SETTINGS:
        # You may want to use something larger, like "-Xmx32g" for real-world
        # usage.
        java_args='-Xmx2g'
    shell:
        'picard '
        '{params.java_args} '
        'MarkDuplicates '
        'INPUT={input.bam} '
        'OUTPUT={output.bam} '
        'REMOVE_DUPLICATES=true '
        'METRICS_FILE={output.metrics} '
        '&> {log}'


rule merge_techreps:
    """
    Technical replicates are merged and then re-deduped.

    If there's only one technical replicate, its unique, nodups bam is simply
    symlinked.
    """
    input:
        lambda wc: expand(
            c.patterns['markduplicates']['bam'],
            sample=common.get_techreps(c.sampletable, wc.label),
            sample_dir=c.sample_dir
        )
    output:
        bam=c.patterns['merged_techreps'],
        metrics=c.patterns['merged_techreps'] + '.metrics'
    log:
        c.patterns['merged_techreps'] + '.log'
    wrapper:
        wrapper_for('combos/merge_and_dedup')


rule bigwig:
    """
    Create a bigwig.

    See note below about normalizing!
    """
    input:
        bam=c.patterns['merged_techreps'],
        bai=c.patterns['merged_techreps'] + '.bai',
    output:
        c.patterns['bigwig']
    params:
        extra='--minMappingQuality 20 --ignoreDuplicates --smoothLength 10'
    log:
        c.patterns['bigwig'] + '.log'
    shell:
        'bamCoverage '
        '--bam {input.bam} '
        '-o {output} '
        '-p {threads} '
        '--minMappingQuality 20 '
        '--ignoreDuplicates '
        '--smoothLength 10 '
        # TEST SETTINGS: for testing, we remove --normalizeUsingRPKM since it
        # results in a ZeroDivisionError (there are less than 1000 reads total).
        # However it is probably a good idea to use that argument with real-world
        # data.
        #'--normalizeUsingRPKM '
        '&> {log}'


rule fingerprint:
    """
    Runs deepTools plotFingerprint to assess how well the ChIP experiment
    worked.

    Note: uses the merged techreps.
    """
    input:
        bams=lambda wc: expand(c.patterns['merged_techreps'], merged_dir=c.merged_dir, label=wc.ip_label),
        control=lambda wc: expand(c.patterns['merged_techreps'], merged_dir=c.merged_dir, label=chipseq.merged_input_for_ip(c.sampletable, wc.ip_label)),
        bais=lambda wc: expand(c.patterns['merged_techreps'] + '.bai', merged_dir=c.merged_dir, label=wc.ip_label),
        control_bais=lambda wc: expand(c.patterns['merged_techreps'] + '.bai', merged_dir=c.merged_dir, label=chipseq.merged_input_for_ip(c.sampletable, wc.ip_label)),
    output:
        plot=c.patterns['fingerprint']['plot'],
        raw_counts=c.patterns['fingerprint']['raw_counts'],
        metrics=c.patterns['fingerprint']['metrics']
    threads: 4
    params:
        # Note: I think the extra complexity of the function is worth the
        # nicely-labeled plots.
        labels_arg=lambda wc: '--labels {0} {1}'.format(
            wc.ip_label, chipseq.merged_input_for_ip(c.sampletable, wc.ip_label)
        )
    log: c.patterns['fingerprint']['metrics'] + '.log'
    shell:
        'plotFingerprint '
        '--bamfile {input.bams} '
        '--JSDsample {input.control} '
        '-p {threads} '
        '{params.labels_arg} '
        '--extendReads=300 '
        '--skipZeros '
        '--outQualityMetrics {output.metrics} '
        '--outRawCounts {output.raw_counts} '
        '--plotFile {output.plot} '
        # TEST SETTINGS:You'll probably want to change --numberOfSamples to
        # something higher (default is 500k) when running on real data
        '--numberOfSamples 5000 '
        '&> {log}'


rule macs2:
    """
    Run the macs2 peak caller
    """
    input:
        ip=lambda wc:
            expand(
                c.patterns['merged_techreps'],
                label=chipseq.samples_for_run(config, wc.macs2_run, 'macs2', 'ip'),
                merged_dir=c.merged_dir,
            ),
        control=lambda wc:
            expand(
                c.patterns['merged_techreps'],
                label=chipseq.samples_for_run(config, wc.macs2_run, 'macs2', 'control'),
                merged_dir=c.merged_dir,
            ),
    output:
        bed=c.patterns['peaks']['macs2']
    log:
        c.patterns['peaks']['macs2'] + '.log'
    params:
        block=lambda wc: chipseq.block_for_run(config, wc.macs2_run, 'macs2')
    wrapper:
        wrapper_for('macs2/callpeak')


rule spp:
    """
    Run the SPP peak caller
    """
    input:
        ip=lambda wc:
            expand(
                c.patterns['merged_techreps'],
                label=chipseq.samples_for_run(config, wc.spp_run, 'spp', 'ip'),
                merged_dir=c.merged_dir,
            ),
        control=lambda wc:
            expand(
                c.patterns['merged_techreps'],
                label=chipseq.samples_for_run(config, wc.spp_run, 'spp', 'control'),
                merged_dir=c.merged_dir,
            ),
    output:
        bed=c.patterns['peaks']['spp'],
        enrichment_estimates=c.patterns['peaks']['spp'] + '.est.wig',
        smoothed_enrichment_mle=c.patterns['peaks']['spp'] + '.mle.wig',
        rdata=c.patterns['peaks']['spp'] + '.RData'
    log:
        c.patterns['peaks']['spp'] + '.log'
    params:
        block=lambda wc: chipseq.block_for_run(config, wc.spp_run, 'spp'),
        java_args='-Xmx8g',
        keep_tempfiles=False
    threads: 2
    wrapper:
        wrapper_for('spp')


# rule bed_to_bigbed:
#     """
#     Convert BED to bigBed
#     """
#     input: "data/chipseq/peakcalling/{algorithm}/{label}/{prefix}.bed"
#     output: "data/chipseq/peakcalling/{algorithm}/{label}/{prefix}.bigbed"
#     log: "data/chipseq/peakcalling/{algorithm}/{label}/{prefix}.bigbed.log"
#     run:
#         p = {
#             'macs2': ('assets/narrowPeak.as', '4+6', _narrowpeak),
#             'macs2_lenient': ('assets/narrowPeak.as', '4+6', _narrowpeak),
#             'macs2_broad': ('assets/broadPeak.as', '4+6', _broadpeak),
#             'spp': ('assets/narrowPeak.as', '6+4', _narrowpeak),
#         }
#         _as, bedplus, conversion = p[wildcards.algorithm]
#
#         if conversion is not None:
#             conversion(input[0], input[0] + '.tmp')
#         else:
#             shell('cp {input} {input}.tmp')
#
#         if len(pybedtools.BedTool(input[0])) == 0:
#             shell("touch {output}")
#         else:
#             shell(
#                 """sort -k1,1 -k2,2n {input}.tmp | awk -F "\\t" '{{OFS="\\t"; if (($2>0) && ($3>0)) print $0}}' > {input}.tmp.sorted """
#                 "&& bedToBigBed "
#                 "-type=bed{bedplus} "
#                 "-as={_as} "
#                 "{input}.tmp.sorted "
#                 "dm6.chromsizes "
#                 "{output} &> {log} "
#                 "&& rm {input}.tmp && rm {input}.tmp.sorted")



# vim: ft=python
