# Intent schema decision bench

- model: `gemini-3.1-flash-lite`
- cases: 18

## Summary

| schema | threshold | intent F1 | count acc | review acc | payload quality |
|---|---:|---:|---:|---:|---:|
| score_flat | 0.5 | 0.809 | 0.667 | 0.833 | n/a |
| score_flat | 0.6 | 0.809 | 0.667 | 0.833 | n/a |
| score_flat | 0.7 | 0.800 | 0.611 | 0.833 | n/a |
| boolean_instances | 0.6 | 0.833 | 0.833 | 1.000 | 1.000 |
| boolean_instances_debug | 0.6 | 0.833 | 0.833 | 1.000 | 1.000 |
| boolean_instances_refined | 0.6 | 0.935 | 0.889 | 0.944 | 1.000 |
| instances_review_options | 0.6 | 0.907 | 0.833 | 0.944 | 1.000 |

## Per-case outputs at decision threshold 0.6

- `score_flat` / `single_schedule`: active=['schedule', 'todo'], needs_review=False, f1=0.6667, count_exact=False, review_ok=True
- `score_flat` / `single_todo`: active=['todo', 'schedule'], needs_review=False, f1=0.6667, count_exact=False, review_ok=True
- `score_flat` / `single_knowledge`: active=['todo', 'knowledge'], needs_review=False, f1=0.6667, count_exact=False, review_ok=True
- `score_flat` / `single_memo`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `score_flat` / `schedule_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `score_flat` / `todo_knowledge`: active=['todo', 'knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `score_flat` / `same_type_multi_todo`: active=['todo', 'todo', 'schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `score_flat` / `same_type_multi_schedule`: active=['schedule', 'todo'], needs_review=False, f1=0.4, count_exact=False, review_ok=True
- `score_flat` / `ambiguous_product`: active=['todo', 'memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=False
- `score_flat` / `ambiguous_low_signal`: active=['todo'], needs_review=False, f1=0.0, count_exact=True, review_ok=False
- `score_flat` / `date_not_schedule`: active=['knowledge', 'todo', 'schedule'], needs_review=False, f1=0.5, count_exact=False, review_ok=True
- `score_flat` / `deadline_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `score_flat` / `link_knowledge_todo`: active=['todo', 'knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `score_flat` / `memo_and_todo`: active=['todo', 'memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `score_flat` / `uncertain_two_options`: active=['todo', 'memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=False
- `score_flat` / `knowledge_no_action`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `score_flat` / `todo_goal`: active=['todo', 'schedule'], needs_review=False, f1=0.6667, count_exact=False, review_ok=True
- `score_flat` / `memo_low_review_false`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `single_schedule`: active=['schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `single_todo`: active=['todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `single_knowledge`: active=['todo'], needs_review=False, f1=0.0, count_exact=True, review_ok=True
- `boolean_instances` / `single_memo`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `schedule_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `todo_knowledge`: active=['todo'], needs_review=False, f1=0.6667, count_exact=False, review_ok=True
- `boolean_instances` / `same_type_multi_todo`: active=['todo', 'todo', 'schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `same_type_multi_schedule`: active=['schedule', 'schedule', 'schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `ambiguous_product`: active=['memo'], needs_review=True, f1=0.6667, count_exact=False, review_ok=True
- `boolean_instances` / `ambiguous_low_signal`: active=['todo'], needs_review=True, f1=0.0, count_exact=True, review_ok=True
- `boolean_instances` / `date_not_schedule`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `deadline_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `link_knowledge_todo`: active=['todo', 'knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `memo_and_todo`: active=['todo', 'memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `uncertain_two_options`: active=['memo'], needs_review=True, f1=0.6667, count_exact=False, review_ok=True
- `boolean_instances` / `knowledge_no_action`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `todo_goal`: active=['todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances` / `memo_low_review_false`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `single_schedule`: active=['schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `single_todo`: active=['todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `single_knowledge`: active=['todo'], needs_review=False, f1=0.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `single_memo`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `schedule_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `todo_knowledge`: active=['todo'], needs_review=False, f1=0.6667, count_exact=False, review_ok=True
- `boolean_instances_debug` / `same_type_multi_todo`: active=['todo', 'todo', 'schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `same_type_multi_schedule`: active=['schedule', 'schedule', 'schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `ambiguous_product`: active=['memo'], needs_review=True, f1=0.6667, count_exact=False, review_ok=True
- `boolean_instances_debug` / `ambiguous_low_signal`: active=['todo'], needs_review=True, f1=0.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `date_not_schedule`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `deadline_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `link_knowledge_todo`: active=['todo', 'knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `memo_and_todo`: active=['todo', 'memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `uncertain_two_options`: active=['memo'], needs_review=True, f1=0.6667, count_exact=False, review_ok=True
- `boolean_instances_debug` / `knowledge_no_action`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `todo_goal`: active=['todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_debug` / `memo_low_review_false`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `single_schedule`: active=['schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `single_todo`: active=['todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `single_knowledge`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `single_memo`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `schedule_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `todo_knowledge`: active=['todo', 'memo'], needs_review=True, f1=0.5, count_exact=True, review_ok=False
- `boolean_instances_refined` / `same_type_multi_todo`: active=['todo', 'todo', 'schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `same_type_multi_schedule`: active=['schedule', 'schedule', 'schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `ambiguous_product`: active=['memo'], needs_review=True, f1=0.6667, count_exact=False, review_ok=True
- `boolean_instances_refined` / `ambiguous_low_signal`: active=['memo'], needs_review=True, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `date_not_schedule`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `deadline_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `link_knowledge_todo`: active=['knowledge', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `memo_and_todo`: active=['memo', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `uncertain_two_options`: active=['memo'], needs_review=True, f1=0.6667, count_exact=False, review_ok=True
- `boolean_instances_refined` / `knowledge_no_action`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `todo_goal`: active=['todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `boolean_instances_refined` / `memo_low_review_false`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `single_schedule`: active=['schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `single_todo`: active=['todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `single_knowledge`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `single_memo`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `schedule_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `todo_knowledge`: active=['memo'], needs_review=True, f1=0.0, count_exact=False, review_ok=False
- `instances_review_options` / `same_type_multi_todo`: active=['todo', 'todo', 'schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `same_type_multi_schedule`: active=['schedule', 'schedule', 'schedule'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `ambiguous_product`: active=['memo'], needs_review=True, f1=0.6667, count_exact=False, review_ok=True
- `instances_review_options` / `ambiguous_low_signal`: active=['memo'], needs_review=True, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `date_not_schedule`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `deadline_todo`: active=['schedule', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `link_knowledge_todo`: active=['knowledge', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `memo_and_todo`: active=['memo', 'todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `uncertain_two_options`: active=['memo'], needs_review=True, f1=0.6667, count_exact=False, review_ok=True
- `instances_review_options` / `knowledge_no_action`: active=['knowledge'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `todo_goal`: active=['todo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
- `instances_review_options` / `memo_low_review_false`: active=['memo'], needs_review=False, f1=1.0, count_exact=True, review_ok=True
