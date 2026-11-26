---
layout: post
title: "The data layer: one warehouse, two semantic layers"
date: 2026-11-26 00:30:00 +0000
categories: [research]
description: "A serverless warehouse, dbt models, and the question of where the meaning of a metric lives, when both analysts and an AI agent ask."
---

In [the first post of this series]({{ site.baseurl }}{% post_url 2026-11-26-memory-hierarchy-as-a-lens %}) I said that a data platform is a memory hierarchy made of services, and that a semantic layer decides which meaning of a metric goes into the "cache" for everybody. This post puts together pieces that we built separately: a warehouse and dbt layer from one build, and an AI data agent from another. Put together, they make one reference design for a data layer that serves both analysts and an agent. The question is where the meaning of a metric lives in that design.

The short answer: in two places. That is the most interesting part of the design, and it is not solved yet.

## The shape

![Raw files land in a data lake and load into the warehouse. Inside the warehouse, dbt builds staging views and mart tables in a container job that also runs the tests. From the marts, two semantic layers would read the same tables: dbt metrics, published to a catalog with lineage, a glossary and test results; and an agent metric pack, used by a data agent that answers staff questions in chat and runs SQL as the person who asked. The two definitions of one metric can drift.]({{ site.baseurl }}/assets/diagrams/the-data-layer/data-layer.svg)

The flow is plain on purpose:

- **Raw files** land in object storage, the data lake, and load into the warehouse as they are.
- **dbt** builds the warehouse in two layers. The *staging* layer is views: it cleans names, types and codes, and stores nothing. The *mart* layer is tables: it joins and aggregates, and it is distributed on the key that most joins use.
- **Tests run on every layer** in the same container job, after each build: row counts, value ranges, accepted values, and volume anomalies. Failed rows are kept in their own schema, so a person can look at what broke.
- **The warehouse is Amazon Redshift Serverless.** It bills compute per second (with a 60-second minimum) only while queries run, and it bills storage separately.

## Views and tables are a placement decision

Seen through the lens of the first post, the staging/marts split is a decision about what to keep near the top.

A view keeps nothing. Each query pays to compute it again, from data further down the stack. A table pays one time, at build time, and pays again in storage, but every read after that is cheap. So a model that many people read, many times a day, earns a place as a table. A model that only feeds another model can stay a view.

This is the same rule as a CPU cache: keep what is used again, and accept the cost of keeping it.

## Two semantic layers

A semantic layer gives each metric one name, one formula and one meaning, so "revenue" is the same number in every report. In this design, two consumers need that meaning, and each one reads it from a different place.

**For analysts**, the metrics are dbt semantic models. A script publishes the dbt models, their lineage, their test results and the metric glossary to a data catalog, so an analyst can find a metric, see where it comes from, and see whether its tests passed on the last run.

**For the AI agent**, the metrics live in a *metric pack*: a small set of YAML and CSV files per deployment with the datasets the agent may read, each metric as an aggregate SQL expression, the joins, lookup lists of the names and codes that people type, and 30 to 50 example questions with their SQL. The pack does more than define metrics. The same pack gives the agent's SQL check its allow-list of tables and gives the output filter its masking rules.

The agent needs things that dbt metrics do not carry: the words people use, the examples, and the boundary of what it may touch. That is why the pack exists. The cost is that a metric such as "net revenue" now has two definitions. Nothing in either build checks that they agree.

I see three ways out, and we have not picked one:

1. **Generate the pack's metrics from the dbt project.** dbt stays the only place where a formula is written; the pack adds names, examples and boundaries around it.
2. **Make the pack point at dbt metrics by name** and let a query layer expand them. This is cleaner, but it adds a moving part between the agent and the warehouse.
3. **Keep both and test the agreement:** run each shared metric both ways in CI and fail the build when the numbers differ.

Through the lens, a semantic layer is a cache of meaning. Two caches of the same value need a coherence protocol, or they will drift. Option 3 is that protocol. Options 1 and 2 remove the second copy.

## Every query runs as the person who asked

The second half of the design is about identity.

![A staff member signs in with Entra ID. The chat client passes the same user token to the agent runtime, which verifies issuer, audience, client and expiry; a bad token gets HTTP 401 and no code runs. The verified token is exchanged for an Identity Center token, and the query runs in the warehouse as that person, so their roles and masks apply. A per-person token cache keeps the exchanged token between chat messages. If the person has no permission, the query is refused; there is no fallback role.]({{ site.baseurl }}/assets/diagrams/the-data-layer/identity.svg)

An earlier proof of concept used the simple pattern: one service user in the warehouse per connector, and separate connectors for separate roles. It worked, but the warehouse saw the connector, not the person. Per-person rules, masking and audit would have to be rebuilt above the warehouse.

The design we moved to, built and tested on a separate deployment, keeps the person's identity all the way down:

- The person signs in to the chat client with their Entra ID account. The client sends that user token to the agent.
- The agent runtime verifies the token (issuer, audience, client and expiry) before any of our code runs.
- The agent exchanges the token for an AWS IAM Identity Center token and connects to the warehouse with it. The warehouse sees the person, and the person's own roles and masking policies apply.
- There is no shared or fallback role. If the person may not read a table, the query fails.

One detail cost us time. The token exchange works only one time per user token, and the chat client opens a new session for every message. So a design that exchanged per session worked for the first question and failed on the second. Something must keep the person's identity between messages. One valid pattern caches an identity context and reuses it; the pattern we used caches each person's exchanged token and connects with it. Which one fits depends on what the warehouse endpoint accepts.

Two other rules sit around the query. The model that writes the SQL never sees result rows. And every query passes a read-only check (one SELECT, allowed tables only, a row limit) before it runs, and again inside the warehouse adapter.

This identity path is designed and tested in a sandbox. Some warehouse settings on that path are not yet tested against the production warehouse.

Identity also changes how the caches behave. The warehouse's result cache is shared across sessions, but it serves a cached result only to a user who has permission on the objects in the query. Per-person identity does not throw the cache away; it makes the cache check who is asking.

## The trade-offs

| Decision | What we chose | What it costs | What we get back |
|---|---|---|---|
| Serverless or provisioned compute | Serverless | A cold start after idle; for a steady, all-day load, per-second billing adds up, and provisioned capacity is worth a fresh look | No charge while idle; no capacity planning for a spiky, business-hours load |
| View or table, per model | Views for staging, tables for marts | Build time and storage for the marts | Cheap reads where most reads happen |
| Where a metric is defined | dbt for analysts, a pack for the agent | Two definitions that can drift | The agent gets names, examples and boundaries that dbt does not carry |
| Whose identity runs the query | The signed-in person | A token exchange, a token cache, and more setup | The warehouse's own roles, masks and audit apply to each person |
| Freshness | Batch builds: dbt runs as a job, not a stream | Data is as old as the last run | Compute only when a build runs; tests run on every build, and failures are kept for review |

The first row deserves a number. In one test, the first query after about six hours idle took about 40 seconds: part of that came before the warehouse logged the session, and part was a cold data cache. That is one observation, not a benchmark, and AWS does not publish a resume time. But it is the cost of "no charge while idle", and a person waiting in a chat window feels it.

## How it maps to the hierarchy

| Level in the first post | In this design |
|---|---|
| Result cache | The warehouse result cache, checked per person |
| Warehouse compute with local cache | Serverless compute; empty after idle, which is part of the 40 seconds |
| Managed warehouse storage | The mart tables, the loaded raw tables, and the staging views that compute again from them |
| Data lake | Raw files in object storage, before they load |

And the three questions from the first post:

1. **Where does each piece of data live, and why at that level?** Marts are tables because they are read again; staging is views because it is not.
2. **What is the cost of a miss?** For a dashboard, a slower page. For the agent, a cold start in front of a person, or worse, a metric that disagrees with the dashboard.
3. **Which axis are we trading, and did we say so?** We trade latency after idle for cost, and one definition for an agent that knows the words people use. This post is me saying so.

The next post follows the identity thread further: a chat bot that runs a reimbursement workflow, where every action is the person's own action.
