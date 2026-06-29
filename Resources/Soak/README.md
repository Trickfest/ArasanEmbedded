# Soak And Regression Positions

`lichess_puzzles.tsv` is a small curated subset of the official Lichess puzzle
database. The full database is not vendored in this repository.

## Source

The source export is the Lichess puzzle CSV:

```text
https://database.lichess.org/lichess_db_puzzle.csv.zst
```

Lichess publishes database exports under the Creative Commons CC0 license. See:

```text
https://database.lichess.org/
```

The committed TSV contains only a tiny subset selected for wrapper soak tests
and deterministic search regression tests. See `../../Docs/Testing.md` for test
suite usage and curation policy.

## Normalization

Lichess puzzle rows use this format:

```text
PuzzleId,FEN,Moves,Rating,RatingDeviation,Popularity,NbPlays,Themes,GameUrl,OpeningTags
```

The `FEN` field is the position before the opponent's forcing move. To create
the position that the engine should search:

1. Apply the first UCI move from `Moves` to the source FEN.
2. Store the resulting FEN in the `fen` column.
3. Store the second UCI move from `Moves` as `expected_move`.
4. Store one or more acceptable moves in `allowed_moves`.

Most rows currently use the Lichess solution move as the only allowed move. The
`allowed_moves` column is still present because mate-in-one and tactical
positions can sometimes have more than one engine-equivalent answer.

## Columns

- `id`: Lichess puzzle id.
- `source_fen`: Original Lichess puzzle FEN before the first move is applied.
- `first_move`: First move from the Lichess `Moves` field.
- `fen`: Normalized search position after `first_move`.
- `expected_move`: Second move from the Lichess `Moves` field.
- `allowed_moves`: Comma-separated UCI moves accepted by regression tests.
- `themes`: Lichess puzzle themes.
- `rating`: Lichess puzzle rating at export time.
- `popularity`: Lichess puzzle popularity at export time.
- `source_url`: Lichess game URL from the puzzle row.
- `note`: Curation note.

Do not replace this file with the full Lichess export. If broader coverage is
needed, add a small number of new rows and keep their source/provenance fields
intact.
