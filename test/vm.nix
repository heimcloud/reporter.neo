# NixOS VM test (needs KVM; not part of `nix flake check`):
#   nix build .#vm-test -L
# Real systemd: socket activation, DynamicUser, LoadCredential, the sandbox,
# SO_PEERCRED roles, file modes, oversize rejection, rate limit.
{
  pkgs,
  self,
  inputs,
}:
pkgs.testers.runNixOSTest {
  name = "reporter-send-report";
  node.specialArgs.lib = inputs.neo.lib;
  nodes.machine = {pkgs, ...}: {
    imports = [
      inputs.neo.nixosModules.default
      inputs.neo.nixosModules.base
      self.nixosModules.default
    ];
    neo = {
      core.hostname = "vmhost";
      services.swag.domain = "example.net";
      services.reporter = {
        enabled = true;
        endpoint = "http://127.0.0.1:8099/api/incidents";
        tokenFile = "/var/lib/reporter-test/ingest.token";
        reporterId = "rid-vm";
      };
    };
    users.users.hermes = {
      isSystemUser = true;
      group = "hermes";
    };
    users.groups.hermes = {};
    users.users.alice = {
      isNormalUser = true;
      uid = 1500;
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/reporter-test 0700 root root -"
    ];
    systemd.services.mock-ingest = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./mock_server.py} 8099 /tmp/ingest.log";
    };
  };
  testScript = ''
    import json
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("mock-ingest.service")
    machine.wait_for_open_port(8099)

    # token arrives later (like a sync): the path unit restages it
    machine.succeed("install -m 0600 /dev/null /var/lib/reporter-test/ingest.token")
    machine.succeed("echo vm-secret-token-123 > /var/lib/reporter-test/ingest.token")
    machine.succeed("systemctl start neo-reporter-token.service")
    machine.wait_for_unit("neo-reporter-submit.socket")

    assert machine.succeed("stat -c '%U:%G %a' /run/neo-reporter/creds/token").strip() == "root:root 400"
    assert machine.succeed("stat -c '%U:%G %a' /run/neo-reporter/creds").strip() == "root:root 700"
    assert machine.succeed("stat -c '%a' /run/neo-reporter/submit.sock").strip() == "666"
    machine.fail("sudo -u hermes cat /run/neo-reporter/creds/token")
    machine.fail("sudo -u alice cat /run/neo-reporter/creds/token")
    machine.fail("sudo -u alice grep -r vm-secret /etc/neo-reporter")

    out = machine.succeed("sudo -u alice send-report --dry-run 'dry'")
    assert json.loads(out)["token"] == "present", out
    assert "vm-secret" not in out

    print(machine.succeed("sudo -u hermes send-report --title 'vm test hermes' --unit vm-test.service 'hello from hermes'"))
    print(machine.succeed("echo 'hello from alice' | sudo -u alice send-report --severity warning"))
    print(machine.succeed("send-report 'hello from root'"))
    posts = [json.loads(l) for l in machine.succeed("cat /tmp/ingest.log").splitlines()]
    assert [e["body"]["submitted_by"] for e in posts] == ["hermes", "uid-1500", "root"], posts
    assert all(e["auth"] == "Bearer vm-secret-token-123" for e in posts)
    assert posts[0]["body"]["machine"] == "vmhost" and posts[0]["body"]["reporter_id"] == "rid-vm"
    assert posts[0]["body"]["target_hint"] == "vm test hermes"

    # oversize: client refuses, and a raw client is cut off by the service
    machine.fail("head -c 70000 /dev/zero | tr '\\0' x | sudo -u alice send-report")
    # (socat may exit non-zero: the service closes while it is still writing)
    _, out = machine.execute("head -c 200000 /dev/zero | tr '\\0' y | sudo -u alice ${pkgs.socat}/bin/socat -t 15 - UNIX-CONNECT:/run/neo-reporter/submit.sock")
    assert json.loads(out)["code"] == "too_large", out

    # per-uid rate limit (burst 5; alice used 1)
    for i in range(4):
        machine.succeed(f"sudo -u alice send-report 'burst {i}'")
    rc, out = machine.execute("sudo -u alice send-report 'one too many' 2>&1")
    assert rc == 4 and "rate_limited" in out, (rc, out)
    machine.succeed("sudo -u hermes send-report 'hermes is not limited by alice'")

    # the socket survives a burst of connections
    machine.succeed("for i in $(seq 40); do (echo junk | timeout 20 send-report --dry-run >/dev/null &) ; done; sleep 5")
    machine.succeed("systemctl is-active neo-reporter-submit.socket")
    print(machine.succeed("systemd-analyze security 'neo-reporter-submit@x.service' --no-pager | tail -3 || true"))
    print(machine.succeed("journalctl -u 'neo-reporter-submit@*' --no-pager | tail -20"))
    machine.fail("journalctl --no-pager | grep -q vm-secret-token")
  '';
}
