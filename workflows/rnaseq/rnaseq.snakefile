import sys
sys.path.insert(0, srcdir('../..'))
import os
from textwrap import dedent
import yaml
import tempfile
import pandas as pd
from lcdblib.snakemake import helpers, aligners
from lcdblib.utils import utils
from lib import common
from lib.patterns_targets import RNASeqConfig

# ----------------------------------------------------------------------------
# Note:
#
#  Search this file for the string "# TEST SETTINGS" and make necessary edits
#  before running this on real data.
# ----------------------------------------------------------------------------

include: '../references/references.snakefile'

shell.prefix('set -euo pipefail; export TMPDIR={};'.format(common.tempdir_for_biowulf()))
shell.executable('/bin/bash')

c = RNASeqConfig(config)


def wrapper_for(path):
    return 'file:' + os.path.join('../..','wrappers', 'wrappers', path)

# ----------------------------------------------------------------------------
# RULES
# ----------------------------------------------------------------------------

rule targets:
    """
    Final targets to create
    """
    input:
        (
            c.targets['bam'] +
            utils.flatten(c.targets['fastqc']) +
            utils.flatten(c.targets['libsizes']) +
            [c.targets['fastq_screen']] +
            [c.targets['libsizes_table']] +
            [c.targets['rrna_percentages_table']] +
            [c.targets['multiqc']] +
            utils.flatten(c.targets['featurecounts']) +
            utils.flatten(c.targets['rrna']) +
            utils.flatten(c.targets['markduplicates']) +
            utils.flatten(c.targets['salmon']) +
            #utils.flatten(c.targets['dupradar']) +
            utils.flatten(c.targets['rseqc']) +
            utils.flatten(c.targets['collectrnaseqmetrics']) +
            utils.flatten(c.targets['bigwig']) +
            utils.flatten(c.targets['downstream'])
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


rule hisat2:
    """
    Map reads with HISAT2
    """
    input:
        fastq=rules.cutadapt.output.fastq,
        index=[c.refdict[c.assembly][config['aligner']['tag']]['hisat2']]
    output:
        bam=c.patterns['bam']
    log:
        c.patterns['bam'] + '.log'
    params:
        samtools_view_extra='-F 0x04'
    threads: 6
    wrapper:
        wrapper_for('hisat2/align')


rule rRNA:
    """
    Map reads with bowtie2 to the rRNA reference
    """
    input:
        fastq=rules.cutadapt.output.fastq,
        index=[c.refdict[c.assembly][config['rrna']['tag']]['bowtie2']]
    output:
        bam=c.patterns['rrna']['bam']
    log:
        c.patterns['rrna']['bam'] + '.log'
    params:
        samtools_view_extra='-F 0x04'
    threads: 6
    wrapper:
        wrapper_for('bowtie2/align')


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
        bam='{sample_dir}/{sample}/{suffix}.bam'
    output:
        count='{sample_dir}/{sample}/{suffix}.bam.libsize'
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
        dm6=c.refdict['dmel'][config['aligner']['tag']]['bowtie2'],
        rRNA=c.refdict[c.assembly][config['rrna']['tag']]['bowtie2'],
        phix=c.refdict['phix']['default']['bowtie2']
    output:
        txt=c.patterns['fastq_screen']
    log:
        c.patterns['fastq_screen'] + '.log'
    params: subset=100000
    wrapper:
        wrapper_for('fastq_screen')


rule featurecounts:
    """
    Count reads in annotations with featureCounts from the subread package
    """
    input:
        annotation=c.refdict[c.assembly][config['gtf']['tag']]['gtf'],
        bam=rules.hisat2.output
    output:
        counts=c.patterns['featurecounts']
    log:
        c.patterns['featurecounts'] + '.log'
    shell:
        'featureCounts '
        '-T {threads} '
        '-a {input.annotation} '
        '-o {output.counts} '
        '{input.bam} '
        '&> {log}'

rule rrna_libsizes_table:
    """
    Aggregate rRNA counts into a table
    """
    input:
        rrna=c.targets['rrna']['libsize'],
        fastq=c.targets['libsizes']['cutadapt']
    output:
        json=c.patterns['rrna_percentages_yaml'],
        tsv=c.patterns['rrna_percentages_table']
    run:
        def rrna_sample(f):
            return helpers.extract_wildcards(c.patterns['rrna']['libsize'], f)['sample']

        def sample(f):
            return helpers.extract_wildcards(c.patterns['libsizes']['cutadapt'], f)['sample']

        def million(f):
            return float(open(f).read()) / 1e6

        rrna = sorted(input.rrna, key=rrna_sample)
        fastq = sorted(input.fastq, key=sample)
        samples = list(map(rrna_sample, rrna))
        rrna_m = list(map(million, rrna))
        fastq_m = list(map(million, fastq))

        df = pd.DataFrame(dict(
            sample=samples,
            million_reads_rRNA=rrna_m,
            million_reads_fastq=fastq_m,
        ))
        df = df.set_index('sample')
        df['rRNA_percentage'] = df.million_reads_rRNA / df.million_reads_fastq * 100

        df[['million_reads_fastq', 'million_reads_rRNA', 'rRNA_percentage']].to_csv(output.tsv, sep='\t')
        y = {
            'id': 'rrna_percentages_table',
            'section_name': 'rRNA content',
            'description': 'Amount of reads mapping to rRNA sequence',
            'plot_type': 'table',
            'pconfig': {
                'id': 'rrna_percentages_table_table',
                'title': 'rRNA content table',
                'min': 0
            },
            'data': yaml.load(df.transpose().to_json()),
        }
        with open(output.json, 'w') as fout:
            yaml.dump(y, fout, default_flow_style=False)


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
            utils.flatten(c.targets['rrna_percentages_yaml']) +
            utils.flatten(c.targets['cutadapt']) +
            utils.flatten(c.targets['featurecounts']) +
            utils.flatten(c.targets['bam']) +
            utils.flatten(c.targets['markduplicates']) +
            utils.flatten(c.targets['salmon']) +
            utils.flatten(c.targets['rseqc']) +
            utils.flatten(c.targets['fastq_screen']) +
            utils.flatten(c.targets['collectrnaseqmetrics'])
        ),
        config='config/multiqc_config.yaml'
    output: c.targets['multiqc']
    params:
        analysis_directory=" ".join([c.sample_dir, c.agg_dir]),
        extra='--config config/multiqc_config.yaml',
        outdir=os.path.dirname(c.targets['multiqc'][0]),
        basename=os.path.basename(c.targets['multiqc'][0])
    log: c.targets['multiqc'][0] + '.log'
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
        bam=rules.hisat2.output
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
        'METRICS_FILE={output.metrics} '
        '&> {log}'


rule collectrnaseqmetrics:
    """
    Calculate various RNA-seq QC metrics with Picarc CollectRnaSeqMetrics
    """
    input:
        bam=c.patterns['bam'],
        refflat=c.refdict[c.assembly][config['gtf']['tag']]['refflat']
    output:
        metrics=c.patterns['collectrnaseqmetrics']['metrics'],
        pdf=c.patterns['collectrnaseqmetrics']['pdf']
    params:
        # TEST SETTINGS:
        # You may want to use something larger, like "-Xmx32g" for real-world
        # usage.
        java_args='-Xmx2g',
    log:
        c.patterns['collectrnaseqmetrics']['metrics'] + '.log'
    shell:
        'picard '
        '{params.java_args} '
        'CollectRnaSeqMetrics '
        # From the Picard docs:
        #
        # STRAND=StrandSpecificity
        #     For strand-specific library prep. For unpaired reads, use
        #     FIRST_READ_TRANSCRIPTION_STRAND if the reads are expected to be on the
        #     transcription strand.  Required. Possible values: {NONE,
        #     FIRST_READ_TRANSCRIPTION_STRAND, SECOND_READ_TRANSCRIPTION_STRAND}
        'STRAND=NONE CHART_OUTPUT={output.pdf} '
        'REF_FLAT={input.refflat} '
        'INPUT={input.bam} '
        'OUTPUT={output.metrics} '
        '&> {log}'


rule dupRadar:
    """
    Assess the library complexity with dupRadar
    """
    input:
        bam=rules.markduplicates.output.bam,
        annotation=c.refdict[c.assembly][config['gtf']['tag']]['gtf'],
    output:
        density_scatter=c.patterns['dupradar']['density_scatter'],
        expression_histogram=c.patterns['dupradar']['expression_histogram'],
        expression_boxplot=c.patterns['dupradar']['expression_boxplot'],
        expression_barplot=c.patterns['dupradar']['expression_barplot'],
        multimapping_histogram=c.patterns['dupradar']['multimapping_histogram'],
        dataframe=c.patterns['dupradar']['dataframe'],
        model=c.patterns['dupradar']['model'],
        curve=c.patterns['dupradar']['curve'],
    log: '{sample_dir}/{sample}/dupradar/dupradar.log'
    wrapper:
        wrapper_for('dupradar')


rule salmon:
    """
    Quantify reads coming from transcripts with Salmon
    """
    input:
        fastq=c.patterns['cutadapt'],
        index=c.refdict[c.assembly][config['salmon']['tag']]['salmon'],
    output:
        c.patterns['salmon']
    params:
        index_dir=os.path.dirname(c.refdict[c.assembly][config['salmon']['tag']]['salmon']),
        outdir=os.path.dirname(c.patterns['salmon'])
    log:
        c.patterns['salmon'] + '.log'
    shell:
        'salmon quant '
        '--index {params.index_dir} '
        '--output {params.outdir} '
        '--threads {threads} '
        '--libType=A '
        '-r {input.fastq} '
        '&> {log}'


rule rseqc_bam_stat:
    """
    Calculate various BAM stats with RSeQC
    """
    input:
        bam=c.patterns['bam']
    output:
        txt=c.patterns['rseqc']['bam_stat']
    wrapper: wrapper_for('rseqc/bam_stat')


rule bigwig_neg:
    """
    Create a bigwig for negative-strand reads
    """
    input:
        bam=c.patterns['bam'],
        bai=c.patterns['bam'] + '.bai',
    output: c.patterns['bigwig']['neg']
    threads: 8
    log:
        c.patterns['bigwig']['neg'] + '.log'
    shell:
        'bamCoverage '
        '--bam {input.bam} '
        '-o {output} '
        '-p {threads} '
        '--minMappingQuality 20 '
        '--ignoreDuplicates '
        '--smoothLength 10 '
        '--filterRNAstrand forward '
        '--normalizeUsingRPKM '
        '&> {log}'


rule bigwig_pos:
    """
    Create a bigwig for postive-strand reads
    """
    input:
        bam=c.patterns['bam'],
        bai=c.patterns['bam'] + '.bai',
    output: c.patterns['bigwig']['pos']
    threads: 8
    log:
        c.patterns['bigwig']['pos'] + '.log'
    shell:
        'bamCoverage '
        '--bam {input.bam} '
        '-o {output} '
        '-p {threads} '
        '--minMappingQuality 20 '
        '--ignoreDuplicates '
        '--smoothLength 10 '
        '--filterRNAstrand reverse '
        '--normalizeUsingRPKM '
        '&> {log}'


rule rnaseq_rmarkdown:
    """
    Run and render the RMarkdown file that performs differential expression
    """
    input:
        featurecounts=c.targets['featurecounts'],
        rmd='downstream/rnaseq.Rmd',
        sampletable=config['sampletable']
    output:
        'downstream/rnaseq.html'
    shell:
        'Rscript -e '
        '''"rmarkdown::render('{input.rmd}', 'knitrBootstrap::bootstrap_document')"'''

# vim: ft=python
