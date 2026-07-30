# Alloy release-image security decision

The production Alloy image is rebuilt from the exact Grafana Alloy v1.18.0
source commit `a435563ff073d5355952c1a8d1821110b1392691`. The build updates the
fixable `golang.org/x/text` and `google.golang.org/grpc` dependencies before
compiling the binary.

Trivy also detects three high-severity and two medium-severity advisories in
`github.com/docker/docker@v28.5.2+incompatible`. Grafana's upstream
`.govulncheck.yaml` for the same source commit records that these paths are
Docker daemon handlers while Alloy's cAdvisor dependency imports client code.
The application does not execute those handlers. Production Alloy is limited
to `local.file_match`, `loki.source.file`, processing, and Loki output. It has
read-only access to `/var/lib/docker/containers` and no Docker socket.

The exact non-executable decisions are machine-readable in
`alloy.openvex.json`. The release scanner first requires the unsuppressed
Critical/High findings to equal the three reviewed High records, then applies
that VEX document and requires zero remaining Critical/High findings.

Ten Medium scanner records remain. Seven are duplicate package records for
CVE-2026-27456, whose vulnerable path is the setuid `mount` executable. Both
`mount` and `umount` are deleted from the image, the filesystem is read-only,
all capabilities are dropped, and no interactive user is exposed.
CVE-2026-13757 affects recursive p11-kit RPC parsing; the image contains only
the client library, not an RPC server or socket. The remaining two records are
the non-executed Docker daemon paths described above. Their exact package
versions, owner, decision, and review deadline are machine-readable in
`alloy.medium-risk-acceptance.json`. The scanner requires the Medium inventory
to match that document exactly; any added, removed, or changed record fails.

Review the Medium decisions no later than **2026-10-01**. Review or remove the
Docker VEX decisions no later than **2027-01-01**, and earlier when Grafana
releases an Alloy version that upgrades the affected Docker module. The VEX
document must never be applied to another image or package version.
