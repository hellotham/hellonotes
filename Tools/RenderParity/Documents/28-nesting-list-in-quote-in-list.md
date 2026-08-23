# Onboarding, step by step

1. **Get access.** Ask in `#platform-access` and say which vault you need.

   > Access is granted per collection, not per person, so the answer depends
   > on what you are working on:
   >
   > - Ingest work needs `raw` and `staged`
   > - Index work needs `staged` only
   >   - plus `raw` read-only, if you are debugging a mismatch
   > - Serve work needs neither
   >
   > If you are not sure, ask for `staged` and add the rest later.

2. **Clone and build.** The build is long the first time and short afterwards.

3. **Run the tests.**

   > Two suites, and they fail differently:
   >
   > 1. The unit suite is fast and hermetic. If it fails, it is your change.
   > 2. The integration suite talks to a real vault:
   >    - it is slow
   >    - it is flaky on a cold disk
   >    - a single failure is not a signal; three in a row is
   >
   > Run the unit suite constantly and the integration suite before you push.

4. **Open a draft pull request** on day one, even if it is empty. It is where
   everyone will leave you comments.
