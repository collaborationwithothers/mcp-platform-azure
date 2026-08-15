# Cost

## Platform diagnostic settings

Issue 75 deliberately collects broadly. A target uses the `allLogs` category
group when Azure offers it, otherwise every category returned at apply time.
Every returned metric category is enabled, subject to Azure's exportability
limits. Storage collection covers the whole account and its Blob, File, Queue,
and Table service scopes. These choices can increase Log Analytics ingestion.

`allLogs` is a Microsoft-managed group. If Azure adds a category to it, the
setting can begin collecting that category without a Terraform diff. Do not
publish an ingestion volume or workload cost from this configuration alone.

## Post-deployment measurement procedure, 2026-08-07

After a successful gated deployment has generated representative traffic, use
the shared Log Analytics workspace to measure billable data. Run the following
query over a completed daily window. `_IsBillable` identifies billable records
and `_BilledSize` is their size in bytes.

```kusto
find where TimeGenerated between(startofday(ago(1d))..startofday(now()))
| project _ResourceId, _BilledSize, _IsBillable, Type
| where _IsBillable == true and Type != "Usage"
| summarize BillableDataBytes = sum(_BilledSize) by _ResourceId, Type
| sort by BillableDataBytes desc
```

Use `find` sparingly because it scans tables. For workspace-level volume by
data type, use the `Usage` table instead:

```kusto
Usage
| where TimeGenerated > ago(32d)
| where StartTime >= startofday(ago(31d)) and EndTime < startofday(now())
| where IsBillable == true
| summarize BillableDataGB = sum(Quantity) / 1000. by DataType, Plan
| sort by BillableDataGB desc
```

Record the query period, workload conditions, destination mode, table or
resource breakdown, Azure region, and observed billable volume. Then enter the
measured inputs into the [Azure Monitor Pricing
calculator](https://azure.microsoft.com/pricing/calculator/?service=monitor).
The query patterns and billable fields are documented in [Analyze usage in a Log
Analytics workspace](https://learn.microsoft.com/azure/azure-monitor/logs/analyze-usage).
The [Azure Monitor cost-estimation
guidance](https://learn.microsoft.com/azure/azure-monitor/fundamentals/cost-estimate)
also recommends observing a small group of resources before extrapolating.

Do not convert one short, synthetic, or idle live-test run into a standing
workload price. It is a measurement point, not a forecast. Any later estimate
must say that it is an estimate, give its measurement basis and period, and
state its date.

## Shared observability services

Azure Managed Grafana and the Azure Monitor workspace have a lifecycle separate
from AKS. Stopping AKS does not destroy them. A stopped cluster therefore does
not mean observability costs have stopped.

The replacement Log Analytics workspace and workspace-based Application
Insights resource have a 5 GB daily cap. The cap is a data-loss guardrail, not
a cost ceiling for every observability service. If it is reached, collection
stops for the rest of the day and the missing data cannot be recovered. This
issue adds no cap-reached alert.

Managed Prometheus collection is limited to Microsoft's minimal default profile,
three Argo CD ServiceMonitors, and Istio annotations in two AKS namespaces.
The limits reduce accidental ingestion. They do not prove a billable volume or
monthly cost. Metrics teardown destroys stored Prometheus history. It is not a
cost measurement method.
