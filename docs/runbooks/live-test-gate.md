# Runbook: live-test gate prerequisites

Deploy-time prerequisites the gated live-test principal must hold BEFORE the
apply-call-destroy run, recorded here so they are provisioned up front rather
than discovered at the gate. This complements each module's own "Live-gate
prerequisites" section. Nothing here is applied by PR CI (which runs
`init -backend=false` only).

## Role-assignment write (RBAC bootstrap)

Some modules create role assignments as part of standing up their surface. ARM
requires the deploying principal to hold
`Microsoft.Authorization/roleAssignments/write` at the **scope of each
assignment** (for example the built-in **User Access Administrator** or
**Owner** role at that scope). The gated OIDC principal must therefore hold
role-assignment-write at these scopes before the run:

- **APIM instance** -- `api-center-registry` grants the API Center identity the
  **API Management Service Reader** role there so auto-sync can import APIs
  (`assign_apim_reader_role = true`, the default).
- **API Center instance** -- `api-center-registry` grants **Azure API Center
  Data Reader** there to each principal in `data_reader_principal_ids` (the poll
  principal) for authenticated data-plane read.

If the composition instead grants these roles out of band, set
`assign_apim_reader_role = false` and/or pass `data_reader_principal_ids = []`,
and the deploying principal does not need role-assignment-write.

Amendment recorded 2026-07-12 (ticket 4, PR #21) so ticket 5's integration run
does not fail at the gate on a missing grant.
