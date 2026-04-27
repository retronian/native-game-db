# Retronian Scraper Feedback

Generated from `/home/komagata/UnuOSRoms` while normalizing for MinUI Japanese names.

## Summary

Retronian Scraper successfully normalized matched ROM filenames and zip inner filenames, but the remaining items exposed two data quality buckets for native-game-db:

| Bucket | Count | Meaning |
|---|---:|---|
| unknown | 718 | The ROM did not match by hash. These need pipeline-level classification so known-name/hash-mismatch cases do not appear as generic unknowns. |
| conflict | 59 | Multiple ROMs resolve to the same Japanese filename. These need more specific Japanese titles or variant labels. |

## Systemic Issue Example

`Advanced Dungeons & Dragons - Hillsfar (Japan).zip` was reported as `unknown`.

The game record already exists at `data/games/fc/hillsfar.json`, and the ROM name also exists in `roms[]`:

```text
Advanced Dungeons & Dragons - Hillsfar (Japan)
```

However, the ROM hash from the observed set differed from the existing No-Intro record:

| Field | Observed ROM |
|---|---|
| size | 262160 |
| crc32 | `499cd0ca` |
| md5 | `c54395806312636a0d041f816a0ea4de` |
| sha1 | `5bc6b4d5e2b27983e678376a95b041ecb3abe819` |
| sha256 | `3d5b650f12d6774a05f2cacf33ab4a18a35206689197de382c48cf80710098c4` |

This should not be solved by manually adding one-off alternate dump records. The DB/import pipeline needs a mechanism that prevents this class of false `unknown` from surfacing to consumers.

Required DB-side outcome:

- Consumers should not see `Advanced Dungeons & Dragons - Hillsfar (Japan)` as an undifferentiated unknown when the game and ROM name already exist in native-game-db.
- The DB/API should let consumers distinguish at least these cases:
  - true unknown game
  - known game and exact ROM hash match
  - known game by exact ROM name, but hash mismatch
  - known game by conservative filename match, but low confidence
- Name-matched/hash-mismatched ROMs should be reviewed through a generated workflow, not manually patched one by one.

Possible implementation directions:

- During No-Intro import or a validation pass, generate a review report for observed ROM names that already exist in `roms[].name` but fail hash matching.
- Track No-Intro DAT version/provenance so DAT drift can be separated from bad dumps and alternate dumps.
- Add a lower-confidence matching surface to the API or generated index, clearly separate from verified hash matches.
- Add CI or scripts that consume scraper feedback TSVs and classify items into `missing game`, `known name hash mismatch`, and `title conflict`.

## Data Files

- `reports/retronian-scraper-unconverted-unknown.tsv`
- `reports/retronian-scraper-unconverted-unknown-name-check.tsv`
- `reports/retronian-scraper-unconverted-conflict.tsv`

## Notes

- `unknown` entries should not automatically be treated as missing games. Some, like Hillsfar, are existing games whose ROM name exists in the DB but whose observed hash does not match the stored No-Intro hash.
- `conflict` entries often indicate insufficiently specific Japanese titles, for example generic titles such as `同名映画`.
