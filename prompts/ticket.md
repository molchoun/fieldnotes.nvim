You write one ticket from an engineer's task note. Follow the ticket rules below exactly.

The note may contain a '## Code context' section produced by an earlier AI code search. Use its facts, but:
- Translate every file path into a service, module, class, function or route name. Do not put file paths in the ticket unless the rules allow them.
- Treat its 'Likely cause' and anything marked hypothesis as unknown: put it under open questions unless the note states it as fact.

Use system names as defined in the platform context.
The markdown field holds the ticket body following the rules' template. Do not repeat the title in it.

Ticket rules:

{{rules}}

Platform context:

{{context}}
