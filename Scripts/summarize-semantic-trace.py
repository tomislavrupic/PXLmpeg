#!/usr/bin/env python3
"""Summarize ANE interval overlap, preserving runtime/planned attribution limits."""
import argparse, collections, json, pathlib, statistics, xml.etree.ElementTree as ET

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=pathlib.Path)
    args = parser.parse_args()
    root = args.directory
    report = json.loads((root / 'profile.json').read_text())
    toc = ET.parse(root / 'toc.xml')
    target = toc.find('.//target/process')
    if target is None or target.attrib.get('return-exit-status', '0') != '0':
        raise ValueError('Profile target did not exit successfully')
    if len(report['benchmark']['imagePredictionMilliseconds']) != 100 or len(report['benchmark']['textPredictionMilliseconds']) != 100:
        raise ValueError('Benchmark did not complete 100 measured image/text predictions')
    tree = ET.parse(root / 'ane.xml')
    ids = {e.attrib['id']: e for e in tree.iter() if 'id' in e.attrib}
    def resolve(e):
        while e is not None and 'ref' in e.attrib:
            e = ids[e.attrib['ref']]
        return e
    events = []
    expected = 'mobileclip_' + report['benchmark']['modelName'] + '_'
    for row in tree.findall('.//row'):
        label = resolve(row.find('formatted-label'))
        if label is None:
            continue
        text = label.attrib.get('fmt', ''.join(label.itertext()))
        if (expected not in text and text != 'Neural Engine Prediction') or 'Prediction' not in text:
            continue
        start, duration = resolve(row.find('start-time')), resolve(row.find('duration'))
        if start is None or duration is None:
            continue
        events.append({'startNanoseconds': int(start.text), 'durationNanoseconds': int(duration.text), 'label': text})
    groups = collections.defaultdict(list)
    for event in events:
        groups[event['label']].append(event['durationNanoseconds'] / 1e6)
    batches = {}
    phases = root / 'phases.xml'
    if phases.exists():
        phase_tree = ET.parse(phases)
        phase_ids = {e.attrib['id']: e for e in phase_tree.iter() if 'id' in e.attrib}
        def phase_resolve(e):
            while e is not None and 'ref' in e.attrib:
                e = phase_ids[e.attrib['ref']]
            return e
        for row in phase_tree.findall('.//row'):
            name = phase_resolve(row.find('signpost-name'))
            subsystem = phase_resolve(row.find('subsystem'))
            if name is None or subsystem is None or subsystem.text != 'studio.pixelrecords.pxlmpeg':
                continue
            if name.text not in ['MeasuredImageBatch', 'MeasuredTextBatch']:
                continue
            process = phase_resolve(row.find('process'))
            pid = phase_resolve(process.find('pid')) if process is not None else None
            if pid is None or pid.text != target.attrib.get('pid'):
                continue
            start = int(phase_resolve(row.find('start-time')).text)
            duration = int(phase_resolve(row.find('duration')).text)
            spans = sorted((max(start,e['startNanoseconds']), min(start+duration,e['startNanoseconds']+e['durationNanoseconds'])) for e in events if e['startNanoseconds']<start+duration and e['startNanoseconds']+e['durationNanoseconds']>start)
            merged = []
            for a,b in spans:
                if merged and a <= merged[-1][1]: merged[-1][1] = max(b, merged[-1][1])
                else: merged.append([a,b])
            native = 'imagePredictionMilliseconds' if name.text == 'MeasuredImageBatch' else 'textPredictionMilliseconds'
            batches[name.text] = {'measuredCalls': len(report['benchmark'][native]),
                'batchWallMilliseconds': duration/1e6,
                'nativePredictionWallMilliseconds': sum(report['benchmark'][native]),
                'overlappingANEIntervals': len(spans),
                'aneIntervalUnionMilliseconds': sum(b-a for a,b in merged)/1e6}
    summary = {
        'schemaVersion': 1, 'modelID': report['benchmark']['modelID'],
        'computePolicy': report['benchmark']['computePolicy'],
        'recordingTarget': target.attrib.get('name'),
        'planned': report['plan'],
        'runtimeANEPredictionGroups': {label: {'events': len(ms), 'sumMilliseconds': sum(ms),
            'medianMilliseconds': statistics.median(ms), 'minimumMilliseconds': min(ms), 'maximumMilliseconds': max(ms)}
            for label, ms in groups.items()},
        'measuredBatchOverlap': batches,
        'note': 'Measured ANE hardware intervals during the recording; labels may be model-specific or generic. Counts can include first prediction and warmups; each call may contain multiple ANE partitions. This is runtime ANE participation, not a percentage of all model operations or CPU/GPU wall time. Device plans and cost weights are separate estimates. Attached recordings can lose program labels: generic hardware intervals are time-correlated with PID-scoped batch signposts and are NOT independently process-attributed. Interval wall time is not an exact CPU/ANE operation or utilization percentage. Raw trace may include system context and remains local.'
    }
    (root / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps({'runtimeGroups': summary['runtimeANEPredictionGroups']}, indent=2))

if __name__ == '__main__':
    main()
