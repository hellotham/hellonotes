![The read path, before and after](diagram.png)

The diagram is from the design review and it is already out of date: the cache
sits in front of the coordinator now, not behind it, which is why the dataless
case got faster and the warm case got very slightly slower.

## What changed

- Cache moved in front of coordination
- Coordination is only paid on a miss
- A dataless file is still materialised exactly once

## What did not

The eviction policy. It is still least-recently-used with a fixed cap, and it
is still the wrong policy for a vault where one folder is read constantly and
the rest almost never.
