---
layout: post
title: "The memory hierarchy as a lens"
date: 2026-11-26
categories: [research]
description: "Why the trade-off behind a CPU cache also explains data platforms and AI agents."
---

Most architecture arguments I take part in sound new: serverless or provisioned, a semantic layer in the warehouse or in the BI tool, what an AI agent should remember. Underneath, most of them are one old argument. It is the argument that every computer architect learns first: the memory hierarchy.

This post sets out that lens. The posts after it apply it to real designs.

## One trade-off, five axes

No single memory is fast, large, cheap, and low-power at the same time. So a computer uses a stack of memories, and each level gives up something to get something else.

![The memory hierarchy: registers, cache, DRAM, flash, and disk or object storage, from top to bottom. Upward means faster and less energy per access but more cost per byte; downward means more capacity, less cost per byte, and longer latency.]({{ site.baseurl }}/assets/diagrams/memory-hierarchy-as-a-lens/hierarchy.svg)

I find it useful to name five axes, because a design decision usually trades two or three of them at once:

- **Speed**: how long one access takes (latency).
- **Performance**: how much data moves per second (bandwidth). This is not the same as speed.
- **Cost**: price per byte stored.
- **Size**: how much the level can hold.
- **Power**: energy per access.

The gaps between levels are not small. Peter Norvig's classic table of timings on a typical PC gives orders of magnitude that are still a good mental model:

| Operation | Approximate time |
|---|---|
| Fetch from L1 cache | 0.5 ns |
| Fetch from L2 cache | 7 ns |
| Fetch from main memory | 100 ns |
| Read 1 MB sequentially from memory | 250,000 ns (0.25 ms) |
| Disk seek | 8,000,000 ns (8 ms) |
| Read 1 MB sequentially from disk | 20,000,000 ns (20 ms) |

*Source: [Norvig, "Teach Yourself Programming in Ten Years"](https://norvig.com/21-days.html). These are orders of magnitude from a classic table, not current measurements.*

Energy tells the same story. In their survey of deep-learning hardware, Sze et al. note that DRAM "consumes two orders of magnitude higher energy per access than a small on-chip memory of a few kilobytes", and that "DRAM accesses require up to several orders of magnitude higher energy than computation." Small register files win on energy per bit and lose on area per bit. ([Sze et al., 2017](https://arxiv.org/abs/1703.09039), §V-B.)

Put the five axes side by side and the pattern is plain. Each step down the stack buys capacity and a lower price per byte, and pays for it in speed and in energy per access:

| Level | Speed | Performance | Cost per byte | Size | Power per access |
|---|---|---|---|---|---|
| Registers | Fastest | Highest | Highest | Smallest | Lowest |
| Cache (SRAM) | Very fast (L1 ≈ 0.5 ns) | Very high | Very high | Small | Low |
| Main memory (DRAM) | ≈ 100 ns | High | Moderate | Large | ≈ 100× a small on-chip memory |
| Flash / SSD | Slower | Moderate | Low | Larger | Higher |
| Disk and object storage | Slowest (seek ≈ 8 ms) | Low per stream, high in aggregate | Lowest | Largest | Highest |

*Relative terms, not measurements. The numbers come from the two sources above.*

Every level hides the latency of the level below it, but only for data that is used again. So the design question is never "which memory is best". The question is **what to keep near the top, and what you pay to keep it there.**

## Bigger moves, fewer trips

The second lesson I took from hardware is about bandwidth. Before I worked on cloud systems, I spent time reading interconnect specifications such as PCIe. One idea stayed with me: it is often better to move data in large blocks, even when the consumer needs only part of each block, because the fixed cost of each trip is high. You give up some efficiency per byte to get much more throughput overall.

That is the same balance as a Spark job. A shuffle spreads data across the cluster for parallelism and pays in network traffic. A broadcast copies a small table to every node and pays in memory. Neither is right in general. Which one you pick depends on where the cost falls, the same way it does in hardware.

## The same reasoning, one layer up: the data platform

A modern cloud data platform is a memory hierarchy made of services.

![One trade-off, three layers. Hardware: registers and L1, L2 and L3 cache, DRAM, SSD and disk. Data platform: result cache, warehouse compute with a local SSD cache, managed warehouse storage, data lake on object storage. AI agent: context window, session memory, long-term memory or retrieval index, source systems reached through tools.]({{ site.baseurl }}/assets/diagrams/memory-hierarchy-as-a-lens/mapping.svg)

Read the middle column from top to bottom:

- A **result cache** answers a repeated query without doing any work. It is the fastest level and the smallest one, and it is useless for a new question.
- **Warehouse compute** keeps hot data on local SSD. It is fast, but you pay for it by the hour.
- **Managed warehouse storage** holds all of the warehouse's data, on cheaper storage underneath, and brings blocks up as needed.
- The **data lake** on object storage is the cheapest per byte and the largest. A query that has to reach it pays in latency.

The usual platform debates are placement decisions on this stack. Serverless compute or provisioned compute is a question of what you pay to keep the upper levels warm. Materializing a model or leaving it as a view is a question of whether that data deserves a place near the top. A semantic layer, which I will cover in the next post, decides which meaning of a metric is the one that goes into the "cache" for everybody.

## Two layers up: the AI agent

The right-hand column is where I think the lens is most useful today.

An LLM agent has its own hierarchy. The **context window** is its register file: everything in it is available immediately, it is small, and each token in it costs money and attention on every turn. **Session memory** holds what matters for this conversation. **Long-term memory** and retrieval indexes hold what might matter later. **Source systems**, reached through tools, are the disk: everything is there, and each trip is slow and expensive.

From this view, much of the current agent vocabulary maps onto older ideas in computing:

- **Prompt engineering** is like the early compiler era: writing careful instructions for a fixed instruction set.
- **Fine-tuning** is like extending the instruction set: changing what the substrate understands natively.
- **Context engineering** is memory-system design: what to keep resident, what to evict, what to prefetch, and how to write it down so that it is cheap to load again.

None of this makes agents simple. But it gives me a set of questions that I trust, because computing has answered them before: What is the working set? What is the cost of a miss? What do we prefetch? When is a stale copy acceptable?

## How I use the lens

When I review a design, I ask three questions:

1. **Where does each piece of data live, and why at that level?** If the answer is "because it was easy", the bill or the latency will show it later.
2. **What is the cost of a miss?** A slow dashboard, a wrong answer from an agent, and a cold-start delay are all misses with different prices.
3. **Which axis are we trading, and did we say so?** Every design pays somewhere. A good design says where, to the people who pay.

The next posts in this series apply these questions to real architectures: a data layer, an identity flow from a chat app to the backend, and patient data shared between physicians.
