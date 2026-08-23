# Sampling error

The width of a confidence interval falls with the square root of the sample
size, which is the whole reason a survey of a thousand people is useful and a
survey of a hundred usually is not.

The standard error of the mean is `sigma / sqrt(n)`, and the margin of error at
95% is about `1.96` times that. Four times the sample buys half the interval;
sixteen times buys a quarter.

## What that means in practice

| Sample | Margin of error |
| ---: | ---: |
| 100 | ±10 points |
| 1,000 | ±3 points |
| 10,000 | ±1 point |

- The jump from a hundred to a thousand is worth paying for.
- The jump from a thousand to ten thousand almost never is.

> The interval is about *sampling* error and nothing else. It says nothing
> about who answered the phone, what order the questions came in, or whether
> the people who hung up differ from the people who did not — and those are
> usually larger.

## Reading a published margin

1. Find the sample size. If it is not published, stop reading.

2. Check whether the quoted margin is for the whole sample or for a subgroup:

   > A subgroup of 200 inside a survey of 1,000 carries the margin of a survey
   > of 200, not of 1,000. Papers report the headline figure and then quote
   > subgroup differences against it, which is how a 3-point margin becomes a
   > 7-point one without anybody saying so.

3. Double it before believing a difference between two subgroups.
