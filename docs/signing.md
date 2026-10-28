<!-- doc_type: how-to -->
<!-- doc_tier: integration -->

# Sign Parbake with a stable identity

By default, `task sign` signs the plugin, `parbake` and the guest agent ad hoc. This page shows
how to sign them with an Apple Development identity instead. It also covers what a Developer ID
adds.

With an ad-hoc signature, every build gets a new code identity. The keychain item for the guest
password is therefore created with `-A`, so every application of the user can read it. See
[ADR 0004](adr/adr_0004_keychain_through_the_security_tool.md). A stable identity keeps the same
code identity from one build to the next.

## Choose an identity {#choose-an-identity}

| Identity | Needs | Use |
|---|---|---|
| Ad hoc (`-`) | Nothing | The default, for local builds and CI |
| Apple Development | An Apple Account in Xcode; a free Personal Team is enough | A stable identity on each host that holds its private key |
| Developer ID Application | A paid Apple Developer Program membership | Signed, notarized binaries for other Macs |

Releases ship two ad-hoc-signed OCX packages, `container` and `parbake`, without a Developer ID ([ADR 0015](adr/adr_0015_ship_the_fork_and_parbake_as_two_ocx_packages.md)).

## Create an Apple Development identity {#create-an-apple-development-identity}

1. In Xcode, open Settings, then Accounts, and add your Apple Account.
2. Select the team, click Manage Certificates, click the plus button and choose Apple Development.
   Xcode stores the certificate and its private key in the login keychain.
3. Check that `codesign` can use the identity:

   ```bash
   security find-identity -v -p codesigning
   ```

   The output lists `Apple Development: <account> (<id>)` and ends with `1 valid identities found`.

## Fix "0 valid identities found" {#fix-0-valid-identities-found}

Sometimes `security find-identity -p codesigning` lists the identity, yet the `-v` run counts 0
valid ones. In that case the intermediate certificate Apple Worldwide Developer Relations G3 is
missing. Import it into the login keychain, then check again:

```bash
curl -fsSLo ~/Downloads/AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security add-certificates -k ~/Library/Keychains/login.keychain-db ~/Downloads/AppleWWDRCAG3.cer
security find-identity -v -p codesigning
```

The intermediate certificate needs no trust setting. The Apple Root CA that ships with macOS
covers it.

## Sign with the identity {#sign-with-the-identity}

Pass the identity to `task` through `CODESIGN_IDENTITY`, then read the signature back:

```bash
task sign CODESIGN_IDENTITY="Apple Development: <account> (<id>)"
codesign -dv --verbose=2 "$(task bin-path)/container-runtime-macos" 2>&1 | grep -E 'Authority|TeamIdentifier'
```

The second command prints three authorities and your team ID. The authorities are the identity,
Apple Worldwide Developer Relations and Apple Root CA. `task install` and `task check` take the
same variable, and so does `scripts/dev-env.sh`.

The plugin must share a signing domain with the `container` services it joins.
A source build of apple/container is signed ad hoc, so install the plugin with the ad-hoc identity.
A plugin signed with a team identity cannot attach to an ad-hoc network service.
Its start then fails with "failed to start the DHCP interface on the vmnet network, status 1001".
An attended run on a macOS 27 host measured four combinations:

| Services | Plugin | Result |
|---|---|---|
| ad hoc | ad hoc | the guest boots, gets a DHCP address and answers `exec` |
| team-signed | ad hoc | status 1001 when the guest attaches to the network |
| team-signed | the same team | the guest boots, gets a DHCP address and answers `exec` |
| ad hoc | team-signed | status 1001 |

The plugin loads and starts in every case. Only joining the network of `container-network-vmnet` fails, and only when the signatures differ.
The keychain item needs the identity on `parbake` only, because the plugin never reads it.

`CODESIGN_IDENTITY` signs the plugin and `parbake-agent`. `PARBAKE_CODESIGN_IDENTITY` signs `parbake`
alone and defaults to `CODESIGN_IDENTITY`. `PARBAKE_CODESIGN_OPTS` sets its signing options.
To keep the plugin ad hoc and sign `parbake` with a team identity:

```bash
task sign PARBAKE_CODESIGN_IDENTITY="Apple Development: <account> (<id>)"
```

`scripts/dev-env.sh` passes both identities. CI signs ad hoc.

Pass the identity's name, as `security find-identity -v -p codesigning` prints it in quotes.
`task sign` checks that name, so the SHA-1 hash that `codesign` itself accepts fails the check.

`CODESIGN_IDENTITY` defaults to `-`, the ad-hoc identity. It can also come from the environment.
`task sign` prints `signing with <identity>`. For any other identity, it fails before building when
`security find-identity -v -p codesigning` does not list it. An explicit `CODESIGN_OPTS` still
overrides the default signing options.

## Use a Developer ID {#use-a-developer-id}

A Developer ID Application certificate needs a paid Apple Developer Program membership. Only the
team's Account Holder can create it, in Xcode under Manage Certificates. Binaries signed with it
and notarized with `xcrun notarytool` open on other Macs without a Gatekeeper warning. Parbake
builds from source and is not notarized.
