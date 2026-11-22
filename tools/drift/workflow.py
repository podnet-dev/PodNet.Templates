"""Extract direct pod-nugetizer calls. Never evaluate Actions expressions."""
import json
import re
import sys
from pathlib import Path

import yaml


class Reader(yaml.BaseLoader):
    # BaseLoader preserves `on`, `no` and version-like values as strings.
    def construct_mapping(self, node, deep=False):
        result = super().construct_mapping(node, deep)
        if len(result) != len(node.value) or '<<' in result:
            raise ValueError('duplicate keys or merge keys unsupported')
        return result


def mapping(value):
    if not isinstance(value, dict):
        raise ValueError('expected YAML mapping')
    return value


def username(value, env):
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError('expected scalar NuGet user')
    match = re.fullmatch(r'\$\{\{\s*(vars|secrets|env)\.([\w]+)\s*\}\}', value)
    if match:
        if match[1] == 'env':
            return username(env.get(match[2]), {}) if match[2] in env else 'env.' + match[2]
        return '.'.join(match.groups())
    if '${{' in value:
        raise ValueError('unsupported NuGet username expression')
    return 'literal:' + value


PIPELINE = 'checkout setup test pack integration archive publish release'.split()


def stage_flags(value):
    # Nugetizer validates the tokens, then gates fixed pipeline steps by membership.
    flags = set(filter(None, re.split(r'[,\s]+', value)))
    if (not flags or flags.difference(PIPELINE) or
            flags.intersection({'integration', 'archive', 'publish'}) and 'pack' not in flags or
            'release' in flags and 'publish' not in flags):
        raise ValueError('unsupported or invalid Nugetizer stages')
    return [s for s in PIPELINE if s in flags]


def trigger(value):
    if isinstance(value, (list, str)):
        value = dict.fromkeys(value if isinstance(value, list) else [value], '')
    events = []
    for event, options in sorted(mapping(value).items()):
        if event not in ('push', 'release', 'workflow_dispatch', 'pull_request'):
            raise ValueError('unsupported publishing event: ' + event)
        if options in ('', {}):
            events.append(event)
            continue
        filters = mapping(options)
        allowed = {'push': ('tags', 'branches'), 'release': ('types',)}.get(event, ())
        if set(filters).difference(allowed):
            raise ValueError('unsupported publishing event filters: ' + event)
        for key, entries in sorted(filters.items()):
            entries = entries if isinstance(entries, list) else [entries]
            # Only positive alternatives: sorting is unsafe for ordered negations.
            pattern = r'(?:[A-Za-z0-9_./*\-]|\[0-9\]\+)+' if key != 'types' else r'[a-z_]+'
            if not entries or not all(isinstance(s, str) and re.fullmatch(pattern, s) for s in entries):
                raise ValueError('unsupported publishing filter: ' + key)
            entries = sorted(set(entries))
            if len(entries) > 1 and any('*' in s or '[' in s for s in entries):
                raise ValueError('overlapping publishing globs unsupported')
            events.append(event + '.' + key + ':' + ','.join(entries))
    if not events:
        raise ValueError('missing publishing trigger')
    return ';'.join(events)


def extract(root):
    calls = []
    for path in sorted((Path(root) / '.github' / 'workflows').glob('*')):
        if path.suffix.lower() not in ('.yml', '.yaml'):
            continue
        with path.open(encoding='utf-8-sig') as stream:
            doc = mapping(yaml.load(stream, Loader=Reader))
        for job in mapping(doc['jobs']).values():
            steps = mapping(job).get('steps', [])
            if not isinstance(steps, list):
                raise ValueError('expected job steps sequence')
            for step in steps:
                action, _, ref = step.get('uses', '').partition('@')
                if action.lower() not in ('podnet-dev/pod-nugetizer', 'podnet-hungary/pod-nugetizer'):
                    continue
                inputs = mapping(step.get('with', {}))
                stages = stage_flags(inputs.get('stages', ' '.join(PIPELINE)))
                if 'publish' not in stages:
                    continue  # A separate CI validation job is unmanaged.
                if not ref or any(k in scope for scope in (job, step) for k in ('if', 'continue-on-error')) or 'strategy' in job or 'needs' in job:
                    raise ValueError('conditional or indirect action execution unsupported')
                env = {**doc.get('env', {}), **job.get('env', {}), **step.get('env', {})}
                perms = job.get('permissions', doc.get('permissions', {}))
                if perms in ('read-all', 'write-all'):
                    perms = {'*': perms.split('-')[0]}
                if not all(v in ('read', 'write', 'none') for v in mapping(perms).values()):
                    raise ValueError('unknown permission level')
                calls.append(dict(ref=action.lower() + '@' + ref, permissions=mapping(perms),
                                  trigger=trigger(doc.get('on')),
                                  username=username(inputs.get('nuget-user') or env.get('NUGET_USER'), env),
                                  stages=' '.join(stages)))
    return calls


if __name__ == '__main__':
    print(json.dumps(extract(sys.argv[1])))