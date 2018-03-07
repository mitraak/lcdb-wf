#!/usr/bin/env python

"""
Build and upload a track hub of ChIP-seq signals and peaks, with samples, sort
order, selection matrix, colors, and server info configured in a hub config
file.

This module assumes particular filename patterns and peak output. Such
assumptions are indicated in the comments below.
"""

import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))
import re
import argparse
import pandas
import yaml
from trackhub.helpers import sanitize
from trackhub import CompositeTrack, ViewTrack, SubGroupDefinition, Track, default_hub
from trackhub.helpers import filter_composite_from_subgroups, dimensions_from_subgroups, hex2rgb
from trackhub.upload import upload_hub

from lib import chipseq
from lib.patterns_targets import ChIPSeqConfig


ap = argparse.ArgumentParser()
ap.add_argument('config', help='Main config.yaml file')
args = ap.parse_args()

# Access configured options. See comments in example hub_config.yaml for
# details
config = yaml.load(open(args.config))
hub_config_fn = os.path.join(os.path.dirname(args.config), config['hub_config'])
hub_config = yaml.load(open(hub_config_fn))


hub, genomes_file, genome, trackdb = default_hub(
    hub_name=hub_config['hub']['name'],
    short_label=hub_config['hub']['short_label'],
    long_label=hub_config['hub']['long_label'],
    email=hub_config['hub']['email'],
    genome=hub_config['hub']['genome']
)

c = ChIPSeqConfig(args.config, os.path.join(os.path.dirname(args.config), 'chipseq_patterns.yaml'))

# Set up subgroups based on unique values from columns specified in the config
df = pandas.read_table(config['sampletable'], comment='#')
cols = hub_config['subgroups']['columns']
subgroups = []
for col in cols:
    unique = list(df[col].unique())
    mapping = {
        sanitize(i, strict=True): sanitize(i, strict=False)
        for i in unique
    }

    mapping['NA'] = 'NA'

    s = SubGroupDefinition(
        name=sanitize(col, strict=True),
        label=col,
        mapping=mapping,
    )
    subgroups.append(s)


# Add subgroups for algorithm and peaks-or-not for easier subsetting and
# sorting.
subgroups.append(
    SubGroupDefinition(
        name='algorithm', label='algorithm', mapping={
            'macs2': 'macs2',
            'spp': 'spp',
            'NA': 'NA',
        }))

subgroups.append(
    SubGroupDefinition(name='peaks', label='peaks', mapping={
        'yes': 'yes',
        'no': 'no',
    }))

# Identify the sort order based on the config, and create a string appropriate
# for use as the `sortOrder` argument of a composite track.
to_sort = hub_config['subgroups'].get('sort_order', [])
to_sort += [sg.name for sg in subgroups if sg.name not in to_sort]

# Add the additional subgroups
to_sort += ['algorithm', 'peaks']

sort_order = ' '.join([i + '=+' for i in to_sort])

# Identify samples based on config and sampletable
sample_dir = config['merged_dir']
samples = df['label']

composite = CompositeTrack(
    name=hub_config['hub']['name'] + 'composite',
    short_label='ChIP-seq composite',
    long_label='ChIP-seq composite',
    dimensions=dimensions_from_subgroups(subgroups),
    filterComposite=filter_composite_from_subgroups(subgroups),
    sortOrder=sort_order,
    tracktype='bigWig')

signal_view = ViewTrack(
    name='signalviewtrack', view='signal', visibility='full',
    tracktype='bigWig', short_label='signal', long_label='signal')

peaks_view = ViewTrack(
    name='peaksviewtrack', view='peaks', visibility='dense',
    tracktype='bigBed', short_label='peaks', long_label='peaks')

supplemental_view = ViewTrack(
    name='suppviewtrack', view='supplemental', visibility='full',
    tracktype='bigBed', short_label='Supplemental', long_label='Supplemental')

colors = hub_config.get('colors', [])


def decide_color(samplename):
    """
    Look up the color dictionary in the config and return the first color that
    matches `samplename`.
    """
    for cdict in hub_config.get('colors', []):
        k = list(cdict.keys())
        assert len(k) == 1
        color = k[0]
        v = cdict[color]
        for pattern in v:
            regex = re.compile(pattern)
            if regex.search(samplename):
                return hex2rgb(color)
    return hex2rgb('#000000')


for sample in df['label'].unique():

    # ASSUMPTION: bigwig filename pattern
    bigwig = os.path.join(
        sample_dir, sample,
        sample + '.cutadapt.unique.nodups.bam.bigwig')

    subgroup = df[df.loc[:, 'label'] == sample].to_dict('records')[0]
    subgroup = {
        sanitize(k, strict=True): sanitize(v, strict=True)
        for k, v in subgroup.items()
    }
    subgroup['algorithm'] = 'NA'
    subgroup['peaks'] = 'no'

    signal_view.add_tracks(
        Track(
            name=sanitize(sample + os.path.basename(bigwig), strict=True),
            short_label=sample,
            long_label=sample,
            tracktype='bigWig',
            subgroups=subgroup,
            source=bigwig,
            color=decide_color(sample),
            altColor=decide_color(sample),
            maxHeightPixels='8:35:100',
            viewLimits='0:500',
        )
    )

# The peak-calling runs are effectively keyed by (label, algorithm). There can
# be multiple samples for each peak-calling run, and there is always at least
# an IP and an input. However UCSC does not support multiple tags for
# a subgroup, so we can't just add all relevant tags.
#
# One option would be to create a separate composite. However, this would
# defeat the purpose of including the peaks in the same view such that they can
# be sorted alongsize the signal. I think a better option is to identify if
# there is a consistent value across the subgroup columns for the IP samples.
# If so, add that subgroup.
#
# (this will be a bunch of mucking about with pandas dataframes and counting
# uniques)

pd = chipseq.peak_calling_dict(config)

cols = hub_config['subgroups']['columns']

for (label, algorithm), v in pd.items():

    # only care about the IP
    sub_df = df[df['label'].isin(v['ip'])]

    # For each configured subgroup column, add it only if there's exactly one
    # value for these IPs. This will always be the case if there's only one IP
    # used in the peak-calling run.
    subgroup = {}
    for col in df.columns:
        k = sanitize(col, strict=True)
        if sub_df[col].nunique() == 1:
            v = sanitize(sub_df[col].iloc[0], strict=True)
        else:
            v = 'NA'
        subgroup[k] = v

    subgroup['algorithm'] = algorithm
    subgroup['peaks'] = 'yes'

    # ASSUMPTION: BED filename pattern
    bed_filename = os.path.join(
        config['peaks_dir'],
        algorithm,
        label,
        'peaks.bed')

    # ASSUMPTION: bigBed filename pattern
    bigbed_filename = os.path.join(
        config['peaks_dir'],
        algorithm,
        label,
        'peaks.bigbed')

    _type = chipseq.detect_peak_format(bed_filename)
    if _type == 'narrowPeak':
        tracktype = 'bigNarrowPeak'
    else:
        tracktype = 'bigBed'
    tracktype = 'bigBed'

    peaks_view.add_tracks(
        Track(
            name=sanitize(algorithm + label, strict=True),
            short_label='{0} {1}'.format(algorithm, label),
            long_label='{0} {1}'.format(algorithm, label),
            tracktype=tracktype,
            source=bigbed_filename,
            subgroups=subgroup,
            color=decide_color(bigbed_filename),
            visibility='dense')
    )


supplemental = hub_config.get('supplemental', [])
if supplemental:
    composite.add_view(supplemental_view)
    for block in supplemental:
        supplemental_view.add_tracks(Track(**block))


# Tie everything together
composite.add_subgroups(subgroups)
trackdb.add_tracks(composite)
composite.add_view(signal_view)
composite.add_view(peaks_view)

# Render and upload using settings from hub config file
hub.render()
kwargs = hub_config.get('upload', {})
upload_hub(hub=hub, **kwargs)