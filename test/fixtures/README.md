# Golden fixtures

These binary fixtures cover the v0.1 COTP and S7comm wire surface.

The Setup and Read Var S7 payloads were extracted from the captures documented in
`resources/gmiru-s7comm/capture-catalog.md`, pinned there to commit
`88f35a601de45fa29b0b36048a30ae4a1e925320` of `gymgit/s7-pcaps`.

The COTP control/data frames and the single-bit Write Var pair are normalized from the same
capture set and the corresponding decoded observations. Fixture assertions always check both
directions:

```text
fixture -> decode -> expected struct
expected struct -> encode -> fixture
```

Regenerate the `.bin` files from their reviewed hexadecimal source with:

```bash
elixir scripts/build_test_fixtures.exs
```
