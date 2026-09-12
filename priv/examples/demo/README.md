# Demo and QA samples

The homepage links to `/demo`. The hub opens real reviews seeded by `Reviews.DemoReview.seed!/0`, both during release migration and with `mix run priv/repo/seeds.exs` locally.

`Reviews.DemoCatalog.scenarios/0` owns the sample list and manual checklists. Markdown, revisions/discussions, file statuses, and a generated large diff have dedicated samples. Account, CLI/API, accessibility, theme, and responsive checks are listed in the hub as well. Interactive account actions retain normal authentication; preview deployments still require working OAuth to exercise them in the browser.

Samples are shared. Re-seeding preserves existing reviews and comments. To revise a fixture, bump its catalog slug version so a deployment creates the new sample without overwriting visitors' work. Keep old versions accessible at their existing URLs.

When adding a feature, add a sample or checklist item here and a corresponding catalog/LiveView test. The browser checklist records manual progress only; it is not an automated test result. Reset checklist clears only those browser checkmarks.
