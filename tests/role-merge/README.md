# tests/role-merge — the merge's test vectors (issue #2783, EPIC #2781 C2)

A role's definition (`agents/<role>.md`) merged with a person's layers. The
node's python copy (`bin/fleet-role.py merge`) left with the role programs
(issue #4340, EPIC #4333 C7); the hub's Go copy (`tokenledger/internal/rolemerge`,
issue #2787) still runs every case in `go test ./internal/rolemerge/` until the
person's role layer goes (#3130), and these files go with it. One JSON per case,

    {name, why, role,
     base:   {front: {...}, body: "..."}           # or {text: "<agents/*.md>"}
     layers: [{label, kind: person|local, front: {...}, body: "..."}   # or {label, kind, text}
              …],                                  # low → high
     locks:  ["<field>", …],                       # conf/agent-locked.list's role.<role>.<field>
     expect: {fields, body, sources, locked, refused}}

`refused` lists the layers (by index) that were not used because a key or value
is not one a layer may carry. `sources[<field>]` lists who shaped it, low → high:
`agents` (the built-in), a layer's label, `lock`.
