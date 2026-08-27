#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Helm post-renderer plugin that applies Kustomize patches to rendered manifests.
# Usage: helm install ... --post-renderer kustomize-post-renderer --post-renderer-args <kustomize-dir>

set -euo pipefail

KUSTOMIZE_DIR="${1:?Usage: --post-renderer-args <path-to-kustomize-dir>}"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/all.yaml.raw"

# Some upstream charts emit duplicate YAML mapping keys (e.g. nico-flow's
# labels + selectorLabels both output app.kubernetes.io/name). kubectl
# tolerates this but kustomize v5's strict YAML parser rejects it.
# Round-trip through Python's yaml parser which silently deduplicates keys.
#
# Also auto-numbers subnet4[].id in any kea_config.json ConfigMap: the
# nico-dhcp chart's template never emits one, and Kea 3.0+ requires it
# (see nico-core.yaml's nico-dhcp comment). Lets structured config.kea.*
# values work without a hand-written keaConfigJsonRaw blob.
python3 -c "
import json, yaml
content = open('$TMPDIR/all.yaml.raw').read()
docs = [doc for doc in yaml.safe_load_all(content) if doc is not None]
for doc in docs:
    if doc.get('kind') != 'ConfigMap':
        continue
    data = doc.get('data') or {}
    raw = data.get('kea_config.json')
    if not raw:
        continue
    try:
        kea = json.loads(raw)
    except ValueError:
        continue
    subnets = kea.get('Dhcp4', {}).get('subnet4', [])
    changed = False
    for i, subnet in enumerate(subnets, start=1):
        if 'id' not in subnet:
            subnet['id'] = i
            changed = True
    if changed:
        data['kea_config.json'] = json.dumps(kea, indent=2)
for doc in docs:
    print('---')
    print(yaml.dump(doc, default_flow_style=False, width=200), end='')
" > "$TMPDIR/all.yaml"

cp -r "$KUSTOMIZE_DIR/"* "$TMPDIR/"

cd "$TMPDIR"
kustomize build .
