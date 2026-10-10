# tests/role-merge — the merge's test vectors (issue #2783, EPIC #2781 C2)

A role's definition (`agents/<role>.md`) is merged with a person's layers by
`bin/fleet-role.py merge` (python) and, on the hub, by C6's Go copy. Both are
held to these files: one JSON per case,

    {name, why, role,
     base:   {front: {...}, body: "..."}           # or {text: "<agents/*.md>"}
     layers: [{label, kind: person|local, front: {...}, body: "..."}   # or {label, kind, text}
              …],                                  # low → high
     locks:  ["<field>", …],                       # conf/agent-locked.list's role.<role>.<field>
     expect: {fields, body, sources, locked, refused}}

`refused` lists the layers (by index) that were not used because a key or value
is not one a layer may carry. `sources[<field>]` lists who shaped it, low → high:
`agents` (the built-in), a layer's label, `lock`.

Run one: `bin/fleet-role.py merge --vector tests/role-merge/04-list-add-remove.json`.
`bin/fleet-role-merge-selftest.sh` runs them all. A new case: write it without
`expect`, run the line above, read the answer, then paste it in.
