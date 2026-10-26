"""Generate a source-pinned startup hook and preserve unrelated launcher YAML."""

import base64
import copy
import hashlib
import json
import re
import zlib

import yaml
from yaml.nodes import MappingNode, ScalarNode, SequenceNode
from yaml.tokens import AliasToken, AnchorToken

HOST = "web.push.apple.com"
TAG = "isbf-apple-web-push-direct-v1"
KEYS = ("no_proxy", "NO_PROXY")


class UniqueLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        keys = [self.construct_object(key, deep=deep) for key, _ in node.value]
        if len(keys) != len(set(keys)) or "<<" in keys:
            raise ValueError("duplicate or merged mapping requires review")
        return super().construct_mapping(node, deep=deep)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load(raw):
    text = raw.decode("utf-8")
    if "\r" in text or not text.endswith("\n"):
        raise ValueError("LF terminated configuration required")
    if any(isinstance(token, (AliasToken, AnchorToken)) for token in yaml.scan(text)):
        raise ValueError("aliased configuration requires review")
    value = yaml.load(text, Loader=UniqueLoader)
    if not isinstance(value, dict):
        raise ValueError("configuration must be a mapping")
    return text, value, yaml.compose(text)


def child(node, name):
    if not isinstance(node, MappingNode) or node.flow_style:
        raise ValueError("block mapping required")
    found = [(key, value) for key, value in node.value if key.value == name]
    if len(found) != 1:
        raise ValueError("expected configuration key missing")
    return found[0]


def add_host(value):
    if not isinstance(value, str):
        raise ValueError("proxy exclusions must be strings")
    tokens = re.split(r"[,\s]+", value)
    return value if HOST in [token.lower() for token in tokens] else value + ("," if value else "") + HOST


def hook_for(installer, policy):
    # Both code and policy live in the protected launcher YAML, never an app-writable path.
    packed = base64.b64encode(zlib.compress(installer)).decode("ascii")
    encoded_policy = base64.b64encode(policy).decode("ascii")
    bootstrap = "\n".join([
        "import base64,hashlib,json,tempfile,zlib",
        "from pathlib import Path",
        "source=zlib.decompress(base64.b64decode(" + repr(packed) + "))",
        "if hashlib.sha256(source).hexdigest()!=" + repr(sha(installer)) + ":raise ValueError('installer source mismatch')",
        "namespace={'__name__':'isbf_apple_web_push_install'}",
        "exec(compile(source,'isbf-apple-web-push/install.py','exec'),namespace)",
        "policy=base64.b64decode(" + repr(encoded_policy) + ")",
        "with tempfile.TemporaryDirectory(prefix='isbf-apple-push-') as folder:",
        " path=Path(folder)/'env-policy.sh'",
        " path.write_bytes(policy)",
        " result=namespace['install'](Path('/etc/service/unicorn/run'),path," + repr(sha(policy)) + ")",
        "print(json.dumps(result,sort_keys=True))",
    ])
    command = "/usr/bin/python3 - <<'ISBF_APPLE_PUSH_PY'\n" + bootstrap + "\nISBF_APPLE_PUSH_PY"
    return {"exec": {"tag": TAG, "cmd": [command]}}


def owned_hook(value):
    hooks = value.get("hooks", {}).get("after_code")
    if not isinstance(hooks, list):
        raise ValueError("existing after_code sequence required")
    matches = [item for item in hooks if isinstance(item, dict) and isinstance(item.get("exec"), dict)
               and item["exec"].get("tag") == TAG]
    if len(matches) > 1:
        raise ValueError("duplicate managed hook")
    return matches[0] if matches else None


def hook_text(root, hook):
    _, hooks = child(root, "hooks")
    key, sequence = child(hooks, "after_code")
    if not isinstance(sequence, SequenceNode) or sequence.flow_style or not sequence.value:
        raise ValueError("nonempty block after_code sequence required")
    indent = sequence.value[0].start_mark.column - 2
    if indent < key.start_mark.column:
        raise ValueError("unsupported hook indentation")
    rendered = yaml.safe_dump([hook], sort_keys=False, width=100000, allow_unicode=False)
    return "".join(" " * indent + line if line.strip() else line for line in rendered.splitlines(True))


def replacements(text, edits):
    for start, end, value in sorted(edits, reverse=True):
        text = text[:start] + value + text[end:]
    return text.encode("utf-8")


def env_edits(root, values):
    _, env = child(root, "env")
    edits = []
    for name, value in values.items():
        _, node = child(env, name)
        if not isinstance(node, ScalarNode) or node.start_mark.line != node.end_mark.line:
            raise ValueError("existing single-line proxy exclusion values required")
        edits.append((node.start_mark.index, node.end_mark.index, json.dumps(value)))
    return edits


def patch_config(raw, hook):
    text, before, root = load(raw)
    env = before.get("env", {})
    proposed = {key: add_host(env.get(key)) for key in KEYS}
    edits = env_edits(root, proposed)
    existing = owned_hook(before)
    if existing is not None and existing != hook:
        raise ValueError("managed hook differs from pinned source")
    if existing is None:
        _, hooks = child(root, "hooks")
        _, sequence = child(hooks, "after_code")
        end = sequence.end_mark.index - sequence.end_mark.column
        edits.append((end, end, hook_text(root, hook)))
    after = replacements(text, edits)
    expected = copy.deepcopy(before)
    expected["env"].update(proposed)
    if existing is None:
        expected["hooks"]["after_code"].append(hook)
    if load(after)[1] != expected:
        raise ValueError("configuration changed outside owned fields")
    return after


def rollback_config(current, before_raw, after_raw, hook):
    if patch_config(before_raw, hook) != after_raw:
        raise ValueError("invalid rollback pair")
    text, now, root = load(current)
    before_text, before, before_root = load(before_raw)
    if owned_hook(before) is not None:
        raise ValueError("rollback baseline already contains the managed hook")
    _, after, after_root = load(after_raw)
    if owned_hook(now) != hook or any(now.get("env", {}).get(key) != after["env"][key] for key in KEYS):
        raise ValueError("owned fields changed after deployment")
    block = hook_text(after_root, hook)
    if text.count(block) != 1:
        raise ValueError("managed hook source changed")
    edits = []
    _, original_env = child(before_root, "env")
    _, current_env = child(root, "env")
    for key in KEYS:
        _, old_node = child(original_env, key)
        _, current_node = child(current_env, key)
        edits.append((current_node.start_mark.index, current_node.end_mark.index,
                      before_text[old_node.start_mark.index:old_node.end_mark.index]))
    start = text.index(block)
    edits.append((start, start + len(block), ""))
    result = replacements(text, edits)
    expected = copy.deepcopy(now)
    expected["env"].update({key: before["env"][key] for key in KEYS})
    expected["hooks"]["after_code"].remove(hook)
    if load(result)[1] != expected:
        raise ValueError("rollback changed unrelated fields")
    return before_raw if current == after_raw else result
