# Weekly reports

One file per week: `YYYY-MM-DD.md`, dated by the **week ending**. Start from
[`TEMPLATE.md`](TEMPLATE.md).

The template's five sections map onto the structure an advisor expects:

| section | question it answers |
|---------|--------------------|
| Idea | why did you do anything at all this week |
| Hypothesis | what did you expect, **and what would have proved you wrong** |
| Test structure | how is the measurement controlled — what varied, what was held fixed |
| Results | the numbers, straight from the instrument, not retold |
| Interpretation | what they mean, including where they disagreed with the prediction |

Two habits that make the reports much stronger:

1. **Write the prediction before the run.** The arithmetic is always available in advance
   — capacity, demand, deficit. A number predicted beforehand and then matched to 0.01 %
   (as in M2-NULL) is far more convincing than the same number explained afterwards.
2. **Keep the failures in.** The saturating-counter mistake, the mis-sized positive
   control, and the two-serial-link discovery are all better report content than the parts
   that worked first time.

Results accumulate in [`../09-results.md`](../09-results.md); the per-run CSVs stay in
`data/` and are not committed.
