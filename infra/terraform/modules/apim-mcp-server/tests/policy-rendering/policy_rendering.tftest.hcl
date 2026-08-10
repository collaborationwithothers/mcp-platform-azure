# Renders the real mcp-server.xml (via ./main.tf's templatefile() call, not a
# reimplementation) against a fixture tool_authorization_map and asserts on
# the generated per-tool <choose> switch cases. Issue 83: the delegated scope
# branch (role_and_scope, scope_only below) has never executed in the live
# gate, because that needs a human-signed-in delegated token no automated
# mechanism can acquire (ADR-006). This is the automated, PR-blocking half of
# the evidence; docs/demos/obo-happy-path.md is the manual, human-run half.
#
# No provider, no backend, no Azure credentials: see main.tf's header comment.

run "renders_all_four_claim_shapes" {
  command = plan

  variables {
    tool_authorization_map = {
      role_only = {
        role = "Orders.Read"
      }
      scope_only = {
        scope = "Orders.Read.AsUser"
      }
      role_and_scope = {
        scope = "Orders.Read.AsUser"
        role  = "Orders.Read"
      }
      unrestricted_tool = {
        unrestricted = true
      }
    }
  }

  # role only -> roles.Contains(role), no scp check for this tool.
  assert {
    condition = (
      regex("case \"role_only\":\\s*allowed = ([^;]+);", output.rendered_policy)[0]
      == "roles.Contains(\"Orders.Read\")"
    )
    error_message = "A role-only tool_authorization_map entry must render as a plain roles.Contains(...) check."
  }

  # scope only -> scp.Contains(scope), no roles check for this tool. This is
  # the branch issue 83 exists to prove: it has never executed live.
  assert {
    condition = (
      regex("case \"scope_only\":\\s*allowed = ([^;]+);", output.rendered_policy)[0]
      == "scp.Contains(\"Orders.Read.AsUser\")"
    )
    error_message = "A scope-only tool_authorization_map entry must render as a plain scp.Contains(...) check."
  }

  # scope AND role together -> OR semantics, matching the per-server check's
  # own OR (a delegated token carries scp and no roles, an app-only token the
  # reverse). This is get_order_status's shape once issue 83 lands.
  assert {
    condition = (
      regex("case \"role_and_scope\":\\s*allowed = ([^;]+);", output.rendered_policy)[0]
      == "(scp.Contains(\"Orders.Read.AsUser\") || roles.Contains(\"Orders.Read\"))"
    )
    error_message = "A tool_authorization_map entry carrying both scope and role must render as (scp.Contains(...) || roles.Contains(...)), matching the per-server check's own OR semantics."
  }

  # unrestricted -> unconditional true, applying no per-tool check at all
  # (get_access_guidance's shape, issue 82; ADR-009 "What unrestricted
  # relaxes").
  assert {
    condition = (
      regex("case \"unrestricted_tool\":\\s*allowed = ([^;]+);", output.rendered_policy)[0]
      == "true"
    )
    error_message = "An unrestricted tool_authorization_map entry must render as an unconditional allowed = true."
  }

  # The static default-deny arm is not driven by the map at all (issue 18);
  # this is a cheap regression guard that nobody has silently removed the
  # fail-closed default while touching this fragment for issue 83.
  assert {
    condition     = strcontains(output.rendered_policy, "default:\n                allowed = false;")
    error_message = "The tool_authorization_map switch must keep an unconditional default: allowed = false; arm (fail-closed for any unmapped tool name)."
  }
}
