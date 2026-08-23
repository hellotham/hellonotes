# Notes on *The Design of Everyday Things*

Read over three weeks in July. Second time; the first was long enough ago that
I remembered the door and nothing else.

## Affordances and signifiers

The distinction that took me two readings to hold onto is that an affordance is
a *relationship* and a signifier is a *communication*. A flat plate on a door
affords pushing whether or not anyone notices; the plate is also the signifier,
which is why it works. A handle on a door that only opens outward affords
pulling and signifies pulling, and lies.

> Affordances exist even if they are not visible. For designers, their
> visibility is critical: visible affordances provide strong clues to the
> operations of things.

The part I underlined twice is that adding a signifier is almost always cheaper
than removing the confusion some other way, and almost always the last thing
anyone tries.

## The gulfs

Two gulfs, and I keep collapsing them into one:

1. The **gulf of execution** — I know what I want; how do I do it here?
2. The **gulf of evaluation** — I did something; what happened?

Most of the software I have shipped is fine on the first and terrible on the
second. A save that succeeds silently and a save that fails silently look
identical from the far side of the second gulf.

## On error

> It is time to reverse the situation: to cast the blame upon the machines and
> their design.

He is not saying people never make mistakes. He is saying that a system where a
predictable slip destroys work is a badly designed system, and that "the
operator should have been more careful" is a design decision wearing a
disguise.

### Slips and mistakes

- A **slip** is the right intention, the wrong action. Typing the correct
  password into the username field.
- A **mistake** is the wrong intention. Deleting the wrong file *on purpose*,
  because you believed it was the other one.

They need different fixes, and treating a mistake as if it were a slip gets you
a confirmation dialogue that nobody reads.

## What I would use tomorrow

- Signifiers before instructions
- Undo before confirmation
- Forcing functions for anything genuinely irreversible
