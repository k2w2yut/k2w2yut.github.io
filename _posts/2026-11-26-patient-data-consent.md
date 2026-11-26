---
layout: post
title: "Patient data that moves only with consent: FHIR on AWS HealthLake"
date: 2026-11-26 01:30:00 +0000
categories: [research]
description: "A design for sharing a patient's record between hospitals and partners, where the patient approves each access: where the copy lives, where consent is checked, and why analytics needs its own path."
---

This is the last post of the series, and it is different from the others. [The data layer]({{ site.baseurl }}{% post_url 2026-11-26-the-data-layer %}) and [the Teams bot]({{ site.baseurl }}{% post_url 2026-11-26-teams-bot-identity %}) came from our own builds. This post is a **design**: an architecture I drew for exchanging patient data between hospitals and their partners, checked against the public AWS documentation. It is not a delivered project, and it has no measurements.

The question is an old one for hospitals. A patient's record lives where the care happened. Another physician, an insurer or a research team needs part of it. In this design, the patient is the owner of the data: the patient approves each access, in fine detail, and can take it back. FHIR gives the record a common shape. It does not decide where the record lives, or where the patient's decision is checked.

Through [the lens of the first post]({{ site.baseurl }}{% post_url 2026-11-26-memory-hierarchy-as-a-lens %}), this is a cache problem with one hard rule: when the patient takes consent back, every copy must act as if it was never made.

## Two shapes

![Two shapes for sharing a patient record. Central store: care sites A and B copy their records into a central FHIR store on AWS HealthLake, and the physician app does one fast read there; it is fast, and available when a site is offline, but every copy must forget when consent ends. Federated exchange: the physician app sends a request to an exchange broker, which asks each care site; there is no extra copy and the data is current at each site, but each read is slower and needs every site online.]({{ site.baseurl }}/assets/diagrams/patient-data-consent/two-shapes.svg)

There are two basic ways to share the record.

- **A central store.** Each care site copies its FHIR resources into one store, and every reader reads from there. On AWS, that store is an AWS HealthLake data store: a managed FHIR R4 server with bulk import and export.
- **Federated exchange.** The record stays at each site. A broker finds which sites hold data for the patient and asks each one when a reader needs it.

In the hierarchy, the central store is a cache near the top: one fast read, no matter how many sites the patient visited. Federated exchange always goes to the bottom: every read is a miss, paid in latency and in the chance that one site is offline. The design chooses the central store, because a physician is often the one waiting. But it buys that speed with a copy, and a copy is the thing that consent makes difficult.

## The design

![The design: the patient decides who reads the record. In the hospital, an HIS data proxy feeds a FHIR format converter. The converter sends data to AWS HealthLake in real time through the FHIR REST API, or in bulk as files that an import handler Lambda loads with an import job. Lake Formation and IAM grants govern analytics, and data scientists query with SQL in Athena. AWS HealthLake uses IAM authorization. A patient app and partners, such as other care providers, an insurer or a research team, call API Gateway, where a Lambda authorizer checks the token scopes. A REST endpoint then calls HealthLake, signed with its own IAM role, and checks the patient's approval (a proposed addition). The patient reads their own record; a partner reads only what was approved. The patient app sends each grant to the identity provider, which handles sign-in and turns the patient's grants into OAuth scopes.]({{ site.baseurl }}/assets/diagrams/patient-data-consent/design.svg)

The design has three parts.

**Data in.** At each hospital, a data proxy reads from the hospital information system (HIS), and a converter turns the records into FHIR resources. New events go to the FHIR REST API of the HealthLake data store in real time. History and large loads go as files to object storage, where an import handler starts a HealthLake import job. The two paths meet in one FHIR store. One record per patient, and not one per hospital, also needs a patient-matching step, because two hospitals write two `Patient` resources for the same person. The drawing does not show that step yet.

**The patient decides.** The patient signs in to a mobile app. When a partner, such as another care provider, an insurer or a research team, asks for access, the patient approves it in the app: which kinds of data, for example lab results only, and for how long. The patient can also revoke an approval. The identity provider turns the active approvals into OAuth scopes, so a partner's token carries only the kinds of data that the patient approved, and lives no longer than the approval.

**Every call is checked.** The FHIR store uses HealthLake's default IAM authorization, so it accepts only signed AWS requests. Partners and the patient app hold no AWS credentials that can call the FHIR store, so the gateway is their only way in. At API Gateway, a Lambda authorizer checks the token and its scopes. Behind it, the REST endpoint calls the FHIR store, signed with its own IAM role. The hospital's converter writes in real time with an IAM role of its own. Under IAM authorization, HealthLake does not read OAuth scopes, and the endpoint's role can read everything. So the endpoint also enforces the kind of data: it adds the approved filter to each search, and checks each resource it returns on a read. The patient reads their own record. A partner reads only what was approved.

That is my reading of the drawing, and the IAM choice matters. HealthLake also offers SMART on FHIR authorization, and a SMART data store accepts a bearer token at its own endpoint. With that option, a partner with a valid token could call the store directly and skip the gateway. The authorization strategy is set when the data store is created, so this is a decision to make on day one.

## Where consent is checked

A consent decision can sit in three places:

1. **When the data is copied.** Only records with consent go into the central store. This is simple, and it is the weakest: after consent ends, the copy is already there.
2. **When the access token is issued.** The identity provider checks the approvals once, and issues a token that can only read what they allow. The check is paid once per session, and a revocation takes effect when the token expires.
3. **When the data is read.** Each call checks the current approval. This is the strongest, and it costs a check on every request.

The drawing uses the second place. I would add the third, in the REST endpoint: before it passes a call on, it checks that the patient's approval is still active. That closes the window between a revocation and the token's expiry, for one lookup per call.

The check belongs in the endpoint, not in the authorizer. A Lambda authorizer sees only headers, query string parameters, stage variables and context variables, not the request body, so a search sent as a POST hides the patient from it. A read by ID, such as `GET /Observation/123`, does not name the patient either, so the endpoint must find the patient that owns the resource before it answers. And if authorizer results are cached, the cache time is a new revocation window.

In hierarchy terms, the token is a cached consent decision, and the per-call check reads the current value every time.

### Why not SMART on FHIR alone

HealthLake's own SMART on FHIR option can carry much of this design. It is worth seeing where it stops.

On a SMART on FHIR data store, HealthLake calls a Lambda function to validate each request's token. The documented event carries the data store endpoint, the operation and the bearer token. It must answer in less than one second, and it returns claims such as `isAuthorized`, `scope` and `exp`. The documented event does not carry the patient or the resource that the request asks for. The Lambda can check with the authorization server that a token is still active, but it cannot check one patient's approval for one resource. That decision must travel inside the token.

The token can carry a lot. HealthLake supports SMART scopes at three levels: `patient` scopes for one patient's data, `user` scopes for what a user can access, and `system` scopes for everything. With SMART on FHIR V2.2 enabled, a scope can also carry a search filter, for example `patient/Observation.rs?category=laboratory`. HealthLake then returns only the resources that match: a read of anything else gets a 403, and a search returns only the matches. That is enough to express "lab results only" inside the data store, with two conditions from the same page: V2.2 must be enabled on the data store, or the filtered scopes are silently ignored, and a broader V2 scope without a filter in the same token grants full access.

Two limits remain. First, the documented fine-grained rule for a practitioner is a different one: with fine-grained authorization on, a practitioner can access the patients that name them as general practitioner (`Patient.generalPractitioner`). That fits a patient's own doctor. It does not fit "the insurer the patient approved last week". Second, the V2.2 filters do not apply to bulk `$export`, which uses V2 scopes. A bulk path needs its own consent control.

So SMART alone puts consent in the token, with the token's lifetime as the revocation window. The gateway design puts the store behind IAM, and lets the endpoint check the patient's current approval on every call.

## Care and analytics need different paths

Care reads one patient's record, with that patient's approval. Analytics reads every row. In the design, data scientists query with SQL in Athena, behind Lake Formation and IAM grants. That path needs one more step than the drawing shows.

![Care reads one record; analytics reads every row. AWS HealthLake keeps Apache Iceberg tables current, one per resource type, append-only and updated asynchronously. A de-identification and consent filter step, a proposed addition, comes next. Lake Formation grants apply only to its output, which data scientists query in Athena. A deleted resource stays as older rows plus a delete marker, so queries must keep only the latest row. If the de-identification step is skipped, an analyst grant reads identified rows.]({{ site.baseurl }}/assets/diagrams/patient-data-consent/analytics.svg)

HealthLake keeps each data store's data as Apache Iceberg tables, one per FHIR resource type. Lake Formation grants decide who can read them, and engines such as Amazon Athena read them in place, without an export. Queries on the tables do not slow the FHIR REST API, because the two interfaces are independent.

Three details in the documentation shape this path:

- **The tables are append-only.** Each create, update and delete adds a row. A delete adds a marker row. A query must keep only the latest row for each resource and drop the delete markers, or it counts old versions and deleted resources.
- **The tables update asynchronously.** AWS says changes typically appear within a few minutes, with no guaranteed freshness target.
- **Grants govern the tables.** Lake Formation grants decide who can read what. The OAuth scopes and the gateway protect the FHIR API, and they do not reach the tables.

So the patient's approvals do not reach analytics by themselves. If I drew the design again, I would add a level between the tables and the data scientists: a step that removes identifiers and drops the records whose approval does not cover research, with Lake Formation grants only on its output. HealthLake gives the tables and the grants, not the consent logic.

This is the same coherence problem as the two metric layers in [the data layer post]({{ site.baseurl }}{% post_url 2026-11-26-the-data-layer %}), with higher stakes. The analytics copy follows the FHIR store a few minutes behind, and a de-identified copy follows the analytics copy. When a patient revokes an approval, each level must forget, in order, and the design must say how long that may take.

## The trade-offs

| Decision | Choice in this design | What it costs | What the design gets back |
|---|---|---|---|
| Central store or federated exchange | One central FHIR store on AWS HealthLake | Every copy must forget when consent ends; hospitals must keep the copy current; patients must be matched across hospitals | One fast read, even when a hospital is offline |
| Real-time or bulk feed | Both: the FHIR REST API for new events, import jobs for history | Two paths to run and reconcile | Fresh data for care, and an efficient path for large loads |
| Where consent is checked | Scopes in the token; proposed addition: an approval check in the REST endpoint on each call | An approval lookup per call, and a patient lookup for a read by ID | On the API path, a revocation takes effect at once, not at token expiry |
| How fine the consent is | Kinds of data as OAuth scopes; the approval period as the grant's lifetime | Scopes must map to what the endpoint can check | "Lab results only" is enforced, not only promised |
| Identified care and analytics | Proposed addition: a de-identified level for research | A de-identification and consent-filter step to build and test | Data scientists never get a grant on identified rows |

## The three questions

1. **Where does each piece of data live, and why at that level?** The care copy lives in the central store, because a physician is waiting. The research copy belongs in a separate, de-identified level, because research needs every row and no names.
2. **What is the cost of a miss?** For care, a miss is a slow or failed read in front of a physician. For consent, the costly error is the opposite of a miss: a stale hit, where a copy or a token serves data after the patient said no. That is why each copy and each token needs a stated lifetime.
3. **Which axis are we trading, and did we say so?** Speed for a copy that must be made to forget. The patient owns the data, so the design must say where each copy is, and how long it may stay wrong.

That closes the series: one lens and three designs, with one question underneath each of them: what do we keep near the top, and what do we pay to keep it there?
