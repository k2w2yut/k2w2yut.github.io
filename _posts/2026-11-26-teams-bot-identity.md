---
layout: post
title: "Keeping the user's identity from Teams to the backend"
date: 2026-11-26 01:00:00 +0000
categories: [research]
description: "A Teams bot that runs a reimbursement workflow: the user's token says who, a narrow app token says where, and the agent keeps the rules in between."
---

[The data layer post]({{ site.baseurl }}{% post_url 2026-11-26-the-data-layer %}) set one rule: every query runs as the person who asked. This post follows that rule into a workflow where the agent does not only read. It writes.

The workflow is expense reimbursement in Microsoft Teams. An employee sends a photo of a receipt to a bot in a 1:1 chat. The agent reads the receipt, fills a claim card, checks the allowance balance, and after the employee confirms, writes the claim to an Excel workbook that HR owns. A late claim goes to the supervisor and then to HR as approval cards in Teams. When HR changes a status in Excel, the employee gets a message.

We built it and ran it in our own demo tenant, on test traffic. Almost every design question in it turned out to be the same question: *whose identity does this step use?*

## Who is asking decides everything

In a reimbursement workflow, identity is not a security layer added at the end. It is the business logic. Whose allowance does this receipt use? Who is this person's supervisor? Who may approve this claim? The rules also say that nobody decides their own claim.

So the agent must know, for certain, who sent each message. And each component must hold only the credential it needs.

![A Teams 1:1 chat sends a message through Azure Bot and API Gateway with a channel token. The Ingress Lambda verifies it and replies fast; a bad channel token or another tenant is refused. It starts the Worker Lambda without waiting. The Worker gets the user's Teams SSO token, or sends a sign-in card if there is none yet, and calls the agent runtime with the user token. The runtime verifies the user token, runs the claim rules, reads the receipt with Textract and Bedrock models, and keeps drafts and locks in a working-state table. To write, it asks AgentCore Identity for an app token, and writes to the HR workbook in SharePoint, the record of truth, through Microsoft Graph on one HR site only.]({{ site.baseurl }}/assets/diagrams/teams-bot-identity/credentials.svg)

Four credentials are in use, and each one has one job:

| Credential | Who holds it | What it is for |
|---|---|---|
| Channel token from Bot Framework | Teams to the Ingress function | Proves the message came through Bot Framework; Ingress then refuses other tenants |
| Bot token (app credentials) | The two Lambda functions | Talks to Bot Framework only: messages, the sign-in token service, and image downloads |
| The user's Entra token (Teams single sign-on) | The Worker, then the agent runtime | Proves *who* the employee is |
| Graph app token | The agent runtime, and the two background functions, each through AgentCore Identity | Reads and writes the HR workbook, uploads receipt images, and looks up users and managers |

The agent runtime checks the user's token before any of our code runs: the signature against our Entra tenant, and the audience. Inside, the code takes the person from the token's tenant and object ID, and looks up their user name in the directory rather than trusting a name in the token.

## The user's token says who; a narrow app token says where

The obvious design is to do everything with the user's token. Write the claim to Excel *as the employee*, and the audit trail is perfect.

It does not work here, and the reason is the most useful idea in this design. **The employee must not be able to open the HR workbook.** It holds every employee's claims. If the bot wrote with the employee's own rights, every employee would need write access to the file, which is the opposite of what HR wants.

So the design splits the two questions:

- **Who** comes from the user's token, verified on every call.
- **Where** the agent may write comes from an app permission: write access to one SharePoint site, plus read access to the user directory to find managers. The agent gets this token from AgentCore Identity and never sees the client secret. AgentCore Identity holds a reference to the secret in the secret store, and the Lambda functions read it only to get the bot token.
- **The rules in between** run in the agent, keyed to the verified person: a receipt file is accepted only from the caller's own upload folder, only the claimant can confirm or cancel their own draft, and an approval tap counts only from the person who holds the open step.

In another project we made the opposite choice. That one was a portal where a power user adds people to Entra groups. There, the backend calls Microsoft Graph *on behalf of* the signed-in power user, with no app permission at all. The person's own rights are exactly the right boundary: Entra already knows which groups they own, and an app permission that can change group membership could change any security group in the tenant.

The rule I take from the two designs:

> Use the person's own rights when the person's rights are the boundary. Use a narrow app right when the boundary is the workflow, and let the agent enforce the workflow for the verified person.

## Fast turns and slow work

Teams expects the bot to answer quickly. Reading a receipt can take many seconds. So a bot turn is split in two:

- The **Ingress** function verifies the channel token, sends a typing indicator, starts the Worker without waiting, and answers Teams. Its time limit is 15 seconds.
- The **Worker** posts a "reading your receipt" message, downloads the file, and calls the agent. When the draft card is ready, it replaces that message in place.

We turned off automatic retries on these functions, so that an action never runs twice by accident. The cost is that a lost action needs the user to tap again, so every action must be safe to repeat:

- A claim's ID comes from its draft's ID, so a second Confirm after a partial failure finds the same row instead of adding another one.
- An approval writes its stamps first and the status cell last. The status cell is the commit. A second tap with the same decision fills only the missing cells; a different decision is refused.
- Short locks stop a double tap from running twice at the same time.

## A spreadsheet as the record of truth

HR already works in Excel, so the workbook in SharePoint is the record of truth, not a database. The agent's own table holds working state: drafts and locks expire, and the last status and the chat address for each employee stay.

This choice is cheap for HR and has real costs:

- The bot finds tables and columns by name, never by cell address, and writes one cell at a time, so a column HR adds is left alone.
- Text from a user that starts with `=` gets a prefix, so it can never become a formula.
- HR can edit the sheet in ways the code does not expect. In the demo workbook, an edit to the status drop-down list removed the "Paid" value, and HR could not close a claim. The fix was a written rule for HR, not code.
- Every action reads the whole claims table. That is fine at test scale, and it grows with the table.

Changes HR makes in Excel come back to the employee through a poller that runs every 15 minutes. It keeps the last status it saw in a small file, so it reads the agent's table only for the rows that changed.

## The hierarchy, again

Two parts of this design are memory-hierarchy decisions in plain sight.

![Reading a receipt: text recognition first. With usable text, route 1, a small model, reads the text. If it is not sure, route 2, a small model, reads the image; unusable text goes straight to route 2. If that is still not sure, route 3, a large model, reads the image. Each route that is sure goes to the draft card. Going down costs more per read. Benchmark on 20 synthetic receipts: 19 read correctly (date, total and type); about 1 in 10 needed the large model.]({{ site.baseurl }}/assets/diagrams/teams-bot-identity/ocr-tiers.svg)

**Reading a receipt works like a cache lookup.** The cheapest level answers first: text recognition, then a small model over the text. Only a "miss" (text that is not usable, or a model that is not sure) goes down to a small model over the image, and only a second miss reaches the large model. "Sure" has a strict meaning: a shop name, a valid date, a total above zero, and a confidence of at least 0.8 on each. On 20 synthetic receipts this read 19 correctly (date, total and type), and about 1 in 10 receipts needed the large model. Real photos are messier, so these numbers need a second measurement on real receipts.

**Keeping the agent session warm is keeping data near the top.** AgentCore Runtime keeps an idle session for 15 minutes by default. On our test traffic, memory was about 88% of the runtime cost per receipt, and most of it was held by idle sessions. We cut the idle timeout to 2 minutes. Memory went from an average of 0.377 GB-hours per receipt on test traffic to 0.062 on one receipt we measured after the change, and a cold start now adds about 5 to 7 seconds when someone comes back later. We also tried stopping the session as soon as the claim was sent. It saved a tiny fraction of a cent per claim, made the next receipt always cold, and needed extra locking. We dropped it.

That is the hierarchy trade-off in one sentence: we pay a few seconds on a miss to stop paying for a level that is mostly empty.

## The trade-offs

| Decision | What we chose | What it costs | What we get back |
|---|---|---|---|
| User token or service account | The user's token for *who*; a narrow app token for *where* | Two credentials to manage; the agent must enforce the per-person rules | Employees never get access to the HR file; every action is tied to a verified person |
| Delegated or app permission for writes | App permission, one site only (the portal project chose delegated) | SharePoint records the app as the editor, so the bot writes the person into the row | HR's file stays closed to staff |
| Synchronous or asynchronous turns | Fast acknowledgement, slow work in a second function | Automatic retries turned off; every action must be safe to repeat | Teams never times out on a slow read |
| Spreadsheet or database as the record | The HR workbook | Full-table reads; HR edits the code does not expect | HR keeps the tool it already uses, and can always fix a row by hand |
| Session idle timeout | 2 minutes instead of 15 | A 5 to 7 second cold start after a pause | Most of the idle memory cost is gone, in one measurement |

The cost model we made before the idle-timeout change put the AWS run cost at under one US cent per receipt at 1,500 receipts a month, on synthetic receipts and test traffic. The idle change makes the real figure lower, and real photos may make it higher. Both need a measurement in production.

## The three questions

1. **Where does each piece of data live, and why at that level?** Claims live in HR's workbook because HR owns them. Drafts and locks live in a table that expires because nobody needs them next week.
2. **What is the cost of a miss?** For a receipt, a slower, more expensive read. For a session, 5 to 7 seconds. For identity, a claim in the wrong person's name, which is why identity is checked on every call and not cached in a name.
3. **Which axis are we trading, and did we say so?** A perfect audit trail in SharePoint for a closed HR file. We chose the closed file and write the person into every row.

The next post moves from expense claims to patient records, where consent decides who may see what.
