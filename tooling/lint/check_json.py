#!/usr/bin/env python3
"""check_json.py — the fixtures match their schemas, and the golden fixtures
match the spec.

Two jobs:

1. **Validate** every file in contracts/fixtures/ against the schema of the same
   name in contracts/schema/. The validator below is a self-contained subset of
   JSON Schema draft 2020-12 — enough for these four schemas and no more. It is
   here rather than `pip install jsonschema` because this has to run on a
   machine with nothing installed, and because a dependency that must be present
   for the lint to run is a lint that does not get run.

2. **Diff the golden fixtures against docs/05-file-contracts.md.** meta.json,
   review.md and review.json are transcribed from the fenced blocks in that
   document, byte for byte, so that unit U6 has an exact target to match. If
   someone edits one and not the other, that is exactly the drift this project
   cannot afford, and it is reported here.

Supported keywords: type, enum, const, required, properties, additionalProperties
(boolean or schema), items, prefixItems, minItems, maxItems, minimum, maximum,
minLength, maxLength, pattern, $ref (local, #/$defs/…), allOf, anyOf, oneOf, not.

Exits non-zero listing every problem.
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SCHEMA_DIR = os.path.join(ROOT, "contracts", "schema")
FIXTURE_DIR = os.path.join(ROOT, "contracts", "fixtures")
SPEC = os.path.join(ROOT, "docs", "05-file-contracts.md")

# fixture filename -> the fenced block in docs/05 it is transcribed from,
# identified by (language, index among blocks of that language).
GOLDEN = {
    "meta.json": ("json", 0),
    "review.md": ("markdown", 0),
    "review.json": ("json", 1),
}

TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "number": (int, float),
    "integer": int,
    "boolean": bool,
    "null": type(None),
}


def resolve(schema, root):
    seen = 0
    while isinstance(schema, dict) and "$ref" in schema and seen < 20:
        ref = schema["$ref"]
        seen += 1
        if not ref.startswith("#/"):
            return {}
        node = root
        for part in ref[2:].split("/"):
            node = node.get(part, {})
        schema = node
    return schema


def type_matches(value, expected):
    python_type = TYPES.get(expected)
    if python_type is None:
        return True
    if expected in ("number", "integer") and isinstance(value, bool):
        return False
    if expected == "number" and isinstance(value, int):
        return True
    return isinstance(value, python_type)


def validate(value, schema, root, path, problems):
    schema = resolve(schema, root)
    if not isinstance(schema, dict) or not schema:
        return

    if "type" in schema:
        expected = schema["type"]
        options = expected if isinstance(expected, list) else [expected]
        if not any(type_matches(value, option) for option in options):
            problems.append(
                f"{path or '<root>'}: expected {' or '.join(options)}, got "
                f"{type(value).__name__}"
            )
            return

    if "enum" in schema and value not in schema["enum"]:
        problems.append(
            f"{path or '<root>'}: {value!r} is not one of {schema['enum']}"
        )
    if "const" in schema and value != schema["const"]:
        problems.append(f"{path or '<root>'}: expected {schema['const']!r}")

    for combiner in ("allOf", "anyOf", "oneOf"):
        if combiner in schema:
            results = []
            for index, sub in enumerate(schema[combiner]):
                sub_problems = []
                validate(value, sub, root, path, sub_problems)
                results.append(sub_problems)
            if combiner == "allOf":
                for sub_problems in results:
                    problems.extend(sub_problems)
            elif combiner == "anyOf" and all(results):
                problems.append(f"{path or '<root>'}: matched no anyOf branch")
            elif combiner == "oneOf" and sum(1 for r in results if not r) != 1:
                problems.append(
                    f"{path or '<root>'}: must match exactly one oneOf branch"
                )

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            problems.append(f"{path}: shorter than minLength {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            problems.append(f"{path}: longer than maxLength {schema['maxLength']}")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            problems.append(
                f"{path}: {value!r} does not match pattern {schema['pattern']}"
            )

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            problems.append(f"{path}: {value} is below minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            problems.append(f"{path}: {value} is above maximum {schema['maximum']}")

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            problems.append(
                f"{path}: {len(value)} items, minimum {schema['minItems']}"
            )
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            problems.append(
                f"{path}: {len(value)} items, maximum {schema['maxItems']}"
            )
        prefix = schema.get("prefixItems", [])
        for index, item in enumerate(value):
            if index < len(prefix):
                validate(item, prefix[index], root, f"{path}[{index}]", problems)
            elif "items" in schema:
                validate(item, schema["items"], root, f"{path}[{index}]", problems)

    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.append(f"{path or '<root>'}: missing required key {key!r}")
        properties = schema.get("properties", {})
        for key, item in value.items():
            child = f"{path}.{key}" if path else key
            if key in properties:
                validate(item, properties[key], root, child, problems)
            else:
                extra = schema.get("additionalProperties", True)
                if extra is False:
                    problems.append(f"{child}: unexpected key")
                elif isinstance(extra, dict):
                    validate(item, extra, root, child, problems)


def golden_blocks():
    if not os.path.exists(SPEC):
        return {}
    with open(SPEC, "r", encoding="utf-8") as handle:
        text = handle.read()
    blocks = {}
    for language, body in re.findall(r"```(\w+)\n(.*?)```", text, re.S):
        blocks.setdefault(language, []).append(body)
    return blocks


def main():
    problems = []

    if not os.path.isdir(SCHEMA_DIR) or not os.path.isdir(FIXTURE_DIR):
        print("check_json: no contracts/ directory yet — nothing to check.")
        return 0

    schemas = {}
    for name in sorted(os.listdir(SCHEMA_DIR)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(SCHEMA_DIR, name)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                schema = json.load(handle)
        except ValueError as error:
            problems.append(f"contracts/schema/{name}: not valid JSON — {error}")
            continue
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            problems.append(
                f"contracts/schema/{name}: $schema must be draft 2020-12"
            )
        schemas[name[: -len(".schema.json")] if name.endswith(".schema.json") else name] = schema

    validated = 0
    for name in sorted(os.listdir(FIXTURE_DIR)):
        path = os.path.join(FIXTURE_DIR, name)
        if not os.path.isfile(path):
            continue
        if name.endswith(".json"):
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    instance = json.load(handle)
            except ValueError as error:
                problems.append(f"contracts/fixtures/{name}: not valid JSON — {error}")
                continue
            stem = name[: -len(".json")]
            schema = schemas.get(stem)
            if schema is None:
                problems.append(
                    f"contracts/fixtures/{name}: no contracts/schema/{stem}.schema.json. "
                    f"Every fixture needs a schema, and every schema needs a fixture."
                )
                continue
            found = []
            validate(instance, schema, schema, "", found)
            validated += 1
            for problem in found:
                problems.append(f"contracts/fixtures/{name}: {problem}")

    # schemas with no fixture
    for stem in sorted(schemas):
        if not os.path.exists(os.path.join(FIXTURE_DIR, stem + ".json")):
            problems.append(
                f"contracts/schema/{stem}.schema.json has no fixture at "
                f"contracts/fixtures/{stem}.json."
            )

    # golden fixtures must still match the spec
    blocks = golden_blocks()
    for name, (language, index) in sorted(GOLDEN.items()):
        path = os.path.join(FIXTURE_DIR, name)
        if not os.path.exists(path):
            problems.append(f"contracts/fixtures/{name} is missing.")
            continue
        candidates = blocks.get(language, [])
        if index >= len(candidates):
            problems.append(
                f"docs/05-file-contracts.md no longer contains {language} block "
                f"#{index + 1}; contracts/fixtures/{name} cannot be verified."
            )
            continue
        with open(path, "r", encoding="utf-8") as handle:
            actual = handle.read()
        if actual != candidates[index]:
            problems.append(
                f"contracts/fixtures/{name} has drifted from "
                f"docs/05-file-contracts.md. The fixture is transcribed from the "
                f"spec byte for byte; change both or neither."
            )

    for problem in problems:
        print(f"check_json: {problem}")
    if problems:
        print(f"check_json: {len(problems)} problem(s).")
        return 1
    print(f"check_json: OK ({validated} fixture(s) validated)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
