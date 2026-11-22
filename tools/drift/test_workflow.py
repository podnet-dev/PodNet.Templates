import tempfile
import unittest
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from workflow import extract


class WorkflowTests(unittest.TestCase):
    def facts(self, doc):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / '.github/workflows'
            folder.mkdir(parents=True)
            (folder / 'publish.yml').write_text(doc, encoding='utf-8')
            return extract(tmp)

    def test_flow_block_and_user_input(self):
        block = "\n".join((
            "on: {push: {tags: ['v[0-9]+.[0-9]+.[0-9]+*']}}", "jobs:", "  publish:",
            "    permissions: {contents: write, id-token: write}", "    steps:",
            "      - uses: podnet-dev/pod-nugetizer@v2",
            "        env: {NUGET_USER: '${{ secrets.NUGET_USER }}'}",
        ))
        flow = "\n".join((
            "'on':", "  push:", "    tags: 'v[0-9]+.[0-9]+.[0-9]+*'",
            "permissions: {id-token: write, contents: write}",
            "jobs: {renamed: {steps: [{uses: actions/checkout@v5}, {with: {nuget-user: '${{secrets.NUGET_USER}}'}, uses: podnet-dev/pod-nugetizer@v2}]}}",
        ))
        self.assertEqual(self.facts(block), self.facts(flow))
        self.assertEqual(self.facts(flow)[0]['username'], 'secrets.NUGET_USER')
        self.assertNotEqual(self.facts(flow), self.facts(flow.replace('secrets.', 'vars.')))

    def test_ambiguous_yaml(self):
        with self.assertRaises(ValueError):
            self.facts('jobs: {}\njobs: {}\n')

    def test_publishing_scope(self):
        jobs = '''\njobs:
  ci: {if: condition, strategy: {matrix: {}}, steps: [{uses: podnet-dev/pod-nugetizer@ci, with: {stages: test}}]}
  cd: {steps: [{uses: podnet-dev/pod-nugetizer@v2, with: {stages: 'publish,pack pack'}}]}
'''
        def facts(on):
            return self.facts('on: ' + on + jobs)
        base = facts("{push: {tags: ['v*']}}")
        self.assertEqual(len(base), 1)
        self.assertEqual(base[0]['stages'], 'pack publish')
        for on in ('push', '[push, workflow_dispatch]', '{release: {types: published}}', '{push: {branches: main}}'):
            self.assertNotEqual(base, facts(on))
        for on in ("{push: {tags: ['v*', '!v2']}}", '{push: {paths: [docs]}}'):
            with self.assertRaises(ValueError):
                facts(on)
        for stages in ('publish', 'test ${{ inputs.extra }}', 'TEST'):
            with self.assertRaises(ValueError):
                self.facts('on: push' + jobs.replace('publish,pack pack', stages))


if __name__ == '__main__':
    unittest.main()