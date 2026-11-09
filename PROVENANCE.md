# Provenance

Rosetta is licensed under the Apache License 2.0 (LICENSE).

## How we made it

The cases are synthetic and named by feature. We used no client or project data.

We generated Rosetta with Vectorworks 2027 (32.1.0, build 885363) on macOS, from scripted recipes
(`driver/inventory/`). A user-interface driver ran a locally prepared copy of Vectorworks. For each document, the
driver opened it, ran its script, saved, reopened and exported it (docs/GENERATING.md). Reproducing Rosetta works
with an unmodified copy (docs/REPRODUCING.md).

## How we cleaned it: structural zeroing

Vectorworks saves leftover process memory inside the documents it writes. In our working copy, that memory held
machine paths, environment variables, a user name and a licence log line. We set the area where that memory sits to
zero, instead of searching for known strings. We call this **structural zeroing**, and we applied it to every
`.vwx`: the sources and the documents saved back to earlier versions.

- **Where.** A record-format node (node type 47) is a 96-byte header followed by N field slots of 136 bytes. N is the
  32-bit value at offset 80. Each slot holds a style, a byte offset, 4 more bytes, and the field name. The name is up
  to 64 UTF-16 characters and ends at a NUL character. The bytes after the NUL, to the end of the slot, are outside
  the format: readers stop at the NUL. Every leaked string we found in the working copy (193 in 38 files) lay in such
  a tail.
- **What we set to zero.** In every type-47 node of every document: the bytes after each slot's name NUL, and any
  bytes after the last slot. The header, the first 8 bytes of each slot and the names are unchanged.
- **How.** We decompressed the node stream, zeroed the regions, and compressed again only the chunks that changed.
  The encoder is a plain Snappy encoder, so a recompressed chunk can grow or shrink a little. The file header keeps
  every byte except the file size at offset 84.
- **Checked, for every document:** the node chain (offset, size and type of each node) is unchanged; bytes changed
  only inside the zeroed regions; and a `.vwx`-to-DXF converter's output, stdout and exit status are byte-identical to the
  original's in all three of its modes. We opened a sample of the zeroed files in Vectorworks Viewer 2027, including
  a 2023-version and an 18-chunk document. They opened without error or repair and looked the same as the originals.
- **Ledger.** `ledger/manifest.json` and `sources/SOURCES.tsv` carry the new sha256 and sizes. The first `sha256` and
  `bytes` columns of `SOURCES.tsv` still record each source as first saved. The table below gives each document's
  original and published sha256, so a holder of the originals can match them.

| file | original sha256 | published sha256 | non-zero bytes zeroed |
|---|---|---|---|
| `files/annotation.bitmap.asym/annotation.bitmap.asym.v2023.vwx` | `f4e135c305a2e0133284112a4fb4460112156c8a06423bd09099fe586b63cb45` | `2eae4ba8ff08723d4e6e020352c4a662ea6899d83fd1a57306cb1ef1ee4590fa` | 5029 |
| `files/annotation.callout.single/annotation.callout.single.v2023.vwx` | `2470db25c6530ee65ef1ac4e33de8cb7cedec630d278862873e6796241b826a8` | `23fa0af02961b5118e1505bbc9fb9c9f0da0438dd21ce2f98ce5a677e99bddcb` | 9585 |
| `files/annotation.dimension.angular/annotation.dimension.angular.v2023.vwx` | `4df5860bbaee669780d32a1ce94f9e687307aa0d3ddd1fef2c1d80f9852ee846` | `db489fbcac47ff7afab9af74106998f8e514ea7a40fe3137173337cb18db3787` | 6562 |
| `files/annotation.dimension.associative/annotation.dimension.associative.v2023.vwx` | `e7804f4b6eb0ef8fe6799f8c2fd0d72541cc69fe26e60debc78ac5c56621ba15` | `bb85ac69cd9c7b5ffd00c19818829d5fad88fbc50915f98cfa4a35aab53cafab` | 7203 |
| `files/annotation.dimension.linear/annotation.dimension.linear.v2023.vwx` | `9427c08b7d9d51eb4c7b958be57d51db43ec00c13f89bf215c669969b358fc8f` | `481620ec6a07f41ead6a823290e9560ac5b8be2a94dc66c8e4e3aa7792fc38ce` | 5651 |
| `files/annotation.dimension.radial/annotation.dimension.radial.v2023.vwx` | `6fec6599215b6fb7f59bfea83f4a8de8909b2f97950b72b3b7d49fd6ab915857` | `80c4970b54c6e0ca339182d5bbcaf48be9afad386453c8c3b0eb17182bdce80f` | 7471 |
| `files/annotation.dimension.units_1_1.cm/annotation.dimension.units_1_1.cm.v2023.vwx` | `0c27527b9f2f6ede905e3d3cb2b99c1170e581e24e6e8c9b1ee80cf94693a960` | `173608934ea9af68df71833dc5119b0b5c104bbe93b6db077e692823529d8de6` | 6870 |
| `files/annotation.dimension.units_1_1.feet_inch/annotation.dimension.units_1_1.feet_inch.v2023.vwx` | `7f83896a70f60780f43a3ec9962c18c11a4cc89e36dbcabb38bdb45edc8493f9` | `7a9e788d70fe935c4a0fd79d3e6df551c67c7f7f920c94a4c1e98cd885e061d9` | 9107 |
| `files/annotation.dimension.units_1_1.inch/annotation.dimension.units_1_1.inch.v2023.vwx` | `78257c0562fe751cf240dd297580aec8364bae026e0f89e2b10b6f1b30ab69c7` | `66bebf5dca3b5ed30693d808fa65272ae7347cfa71ed1532cb40c92f38ee6968` | 6936 |
| `files/annotation.dimension.units_1_1.m/annotation.dimension.units_1_1.m.v2023.vwx` | `0ccfc802f5f37be37805b8cb8ed68d8a29f437953dbee8838bea4bd0d8482b2a` | `1066689b8e64cad91afb1ffde29e9c9489a375ae825b1263c40f30d8533b3280` | 5558 |
| `files/annotation.dimension.units_1_1.mm/annotation.dimension.units_1_1.mm.v2023.vwx` | `83bce960689dc0c02c254b62098cd351ae82ba0d41a7971babd03a55654f238b` | `562a6d860f7bcd4b3f374daef79821671eb401c70508dca4f8852fde44660e2c` | 8930 |
| `files/annotation.sheet.multiple/annotation.sheet.multiple.v2023.vwx` | `85bca9a3a009598873940bdecf5dd84d59ac9071183f1767d81dff2d16e684de` | `61b503d51e162cca10ccb7d1e6da8172e782b0e90bcb8292fc5c278ccd33b936` | 4958 |
| `files/annotation.text.asym/annotation.text.asym.v2023.vwx` | `7808f76909cc53d88e89f3cba29921bf8af6eb2c068b12191cdf479a690456ef` | `59bbff9349092a3fa7875ca281e2af0d7a43ee4fec89ec835beb1c38b64dd014` | 5916 |
| `files/annotation.viewport.elevation/annotation.viewport.elevation.v2023.vwx` | `e9417af7cbf702cd8976af705c35a7fd84dd3aac94efad67f5df539f910e1b22` | `9e16dfd61b7ba370cb1f0814e3d3b1f8bff0534e587f0250d1bb50c2cc90ce52` | 5352 |
| `files/annotation.viewport.sheet/annotation.viewport.sheet.v2022.vwx` | `97fbf2153f3514a18b87687f0dbe6c2475f0545d27930e4100efdb41956053e0` | `2503882c5bc5deea6349c6d149f4f534b24490367bf4fa56e29bc3190f7e8b95` | 7002 |
| `files/annotation.viewport.sheet/annotation.viewport.sheet.v2023.vwx` | `db7eef3f2ad42d5a3762d2f68b1482f260320fff1e6fcf1be13e302be1626731` | `e4acc23acf7c2a5bb9a0009a6fa3f4508712d2be70bfad91989e451a4835be9f` | 7761 |
| `files/annotation.viewport.sheet/annotation.viewport.sheet.v2024.vwx` | `108f91eb996dea393bf92cba5b6820bfc45ba04cdf3986cd7cbfcdece6c0d603` | `7899cf6ce83e9d4d37cdaecb1040ac7cacf779df1c843d3487fb28179846e35e` | 5227 |
| `files/annotation.viewport.sheet/annotation.viewport.sheet.v2025.vwx` | `9acb4de44159740da115418e83e4989b216f1f07de440615eedf5020801c838c` | `f77997afd146f6bc6ef07c1ab960d24403bdc65085c5d7383e6a9faf55af0443` | 6337 |
| `files/annotation.viewport.sheet/annotation.viewport.sheet.v2026.vwx` | `fa311dd3a1cbab31eec745d5f73c4597e4ac87206e9a785ccf159567dfbcd0d3` | `aeff901955fa7a5cddd4a3f6f426c7e46029164b626881b10a8d717385d4713a` | 1819 |
| `files/annotation.worksheet.formula/annotation.worksheet.formula.v2023.vwx` | `5da8ef3f31047a5478b74b2e77dacb15281b4fd7991f0963021a16dafc29c634` | `50e104f6435cfd65e0f906c6104a69c6970b959f5e6d022b6e1467345474a0fd` | 5335 |
| `files/building.column.free/building.column.free.v2023.vwx` | `4580596811806ceeb6bbf3429e98f082b2faed2435806adf6f30fd155837ae98` | `78229b2ff99bc147e33469a95b109b941e2135342112d4439300a0384011f42d` | 9681 |
| `files/building.curtain_wall.straight/building.curtain_wall.straight.v2023.vwx` | `dea6f28fc355807f2e2835781cb3503dd2e9b811f4a38fcd6c486eca276c0732` | `cb92b17f7fb54fbf327a94936e46fe33d9ffc952a834c7f97fbf5bdbeaf633e9` | 4850 |
| `files/building.door.free/building.door.free.v2023.vwx` | `96ff22adf49eccbf7d28fe6f02ca7705617247c6df02c457428cf88ae840404c` | `2afbc4f3514d98d9bee7f05298c2f9f79b8161afbd72d2aef3bbef774f8e32e1` | 21166 |
| `files/building.roof.hip/building.roof.hip.v2023.vwx` | `e8fc4d1840e8332f88b04c1f11164b226afb9ee2087024fe3e500a2400141e79` | `362bac289167b95744211c37825551e3c893885190b1b0fb3ec06589df00930e` | 8856 |
| `files/building.roof.two_edges/building.roof.two_edges.v2023.vwx` | `91b9bc3a7558e73c6f33087eebc6b346db3b7327699a1b0e6011ce571a9f299b` | `4ea9a452b947cdd08142268d8b5f07c0ea59e19c0b62055f13b388f3141a9266` | 5054 |
| `files/building.site_model.points/building.site_model.points.v2023.vwx` | `5c8be22d45a84efb78f156b97fb706b9099d8f319a8982ded4ec8f89ca5eab1a` | `745adc7467eeb35a8d77f4bd2449e51cde36ed5c2d56c476c81bfcab4548a8bc` | 8317 |
| `files/building.slab.profile/building.slab.profile.v2023.vwx` | `9670e4c65a14b4d64e1616fde519f9861105e3cd1459b99a1bf63fe0d897a21d` | `3111cc233be0d0f34e2208ed241228baee099f61f350f9c50af3dfc878ad5484` | 4202 |
| `files/building.space.rect/building.space.rect.v2023.vwx` | `1ee68ea7a608140330ca1b3c2fc7cd62b00961841aff770c7e7f37b7d23ffb8e` | `2f3c111335930543efaed5d069dfe6d616ba0057d1f44b2af95ab2024b77d0e5` | 19831 |
| `files/building.stair.simple/building.stair.simple.v2023.vwx` | `77bdce37d945a94bf03b2172425505b4244a6ebc9cf7b12421412c0476bb18ee` | `76cb5de4bdd558585a862346285d8b2b97ed47758ca583008c4a39c983bbff9f` | 13108 |
| `files/building.wall.straight/building.wall.straight.v2023.vwx` | `2534152ba0294c8d0946775698f8fa5cf5d5d56fa6ebc34f5c2aa109f38b2847` | `b8341c9bcf1e887a7b1b2f29fd913ff6b353beb9bf3b066bc9e2a3632a6a41e3` | 5254 |
| `files/building.wall.with_door_window/building.wall.with_door_window.v2023.vwx` | `9b26b863a6e8a4da3717a61d8fc94bdbb461f9a0bf5d9191534c1e4c9e0938c3` | `276f4c4a851dcd2570bce060422d32270d1d9bebc0c09c65e6ff939f33f0789b` | 74741 |
| `files/building.window.free/building.window.free.v2023.vwx` | `a6eb13c943b99db0f182c73356ea22d87c1956b05eb98954e602e4bb29323d29` | `35556a13c5076424b582313fae14d89766f126acd2df355110e44a09bb0d9204` | 32745 |
| `files/container.group.asym/container.group.asym.v2023.vwx` | `8678840436097ba3f0a992ab0831c981eb626a9ec09f76808c85eacf7913f38e` | `04f1c958da77215a70793fb33b77f8c04c9f3b8e4dfded18ca89fb06f7d5f8ff` | 4751 |
| `files/container.layer.design_elevated/container.layer.design_elevated.v2023.vwx` | `07f002618f1c76476ba67932d1e674c3cd2fb20edfd0a249e12f6a78fc053179` | `1f852cb0c3862d68c38ffeb1d863cc5816ab69cc09b098cd86e1533d56f3c094` | 6374 |
| `files/container.layer_link.design/container.layer_link.design.v2023.vwx` | `46ddde98f329f51617af8c2bdd62413bf89a6b4fdae0a5d82bb2a29cae017730` | `6d4bdd91b52d6efedfdab6abe4f78b39b2a2de5168b7ead419df6072a4bf6c70` | 4473 |
| `files/container.symbol.def_instance/container.symbol.def_instance.v2023.vwx` | `b2731b13744291d766e362ae58f6108ea3b7cd2bdc87c646772d5199c32026b8` | `114f8d9cd624066bbe0febe25ce5a32ae2fb1a42bb8269d1acb457741e6c4f98` | 5071 |
| `files/container.symbol.mirror_3d/container.symbol.mirror_3d.v2023.vwx` | `bcd84c799e36ad46c5314cb9dc6d51bb5003b19e1b15fd8b7b293566290a55d9` | `f63fb074e422180f0eeeb2ded4d078d338f0c262c05d001ebb54b5950380ac25` | 5747 |
| `files/container.symbol.nested_3d/container.symbol.nested_3d.v2023.vwx` | `262ff79bf23d8ef366d685343d2ee6177b89b7b9c51a5088f1e99f1a052fde31` | `beb6dcc9c6831f9b90524f94f7cba82291ef4e779c00f33c4fdbb7730caae819` | 5035 |
| `files/container.symbol.nested/container.symbol.nested.v2023.vwx` | `9c3dc00e073c3701e4edcf825fc374b95a1e13c5068533f0263970ab78aa4b24` | `2d6e34c655d817a6f0f43432b108a85de79712ce2b06a0a0e25d292dec777ebd` | 6138 |
| `files/control.blank.imperial/control.blank.imperial.v2023.vwx` | `8ff478d8368ce32d16cd7506711ba8e075a030c287e82a1de876d060c5f43cf7` | `627f918ec7dc42089827ee64b6656f0cda941acc86b6a7201a246f59cb85c33f` | 5106 |
| `files/control.blank.mm/control.blank.mm.v2023.vwx` | `07b4dc47984ba2a687e7f779122fde6a425cce6d22c4a32763b827097a03c6fe` | `a30bf135bfd2ce4449c801bb0c4bce40bbfa7fb3b63367b17f70fd1bc688d134` | 5338 |
| `files/document.georeference.epsg/document.georeference.epsg.v2023.vwx` | `1564dc702545b4ceffe6b049d72f2d8db71ba7f50e9f7d6d7f24e0f8abad5666` | `21d2f2f98faec6f4c5ea65479a2138210655b8704793477bfa990c3cd87a929f` | 7163 |
| `files/document.layer_scale.1_100/document.layer_scale.1_100.v2023.vwx` | `c5a48cc3e649b23513c8d9b73132cae97e5558d66e1a4118aac07eee5bfe4b84` | `efaaba1f6a1409217c320dd2b50fa5e32848dd58461fc8faa37abf69c43f5a40` | 5974 |
| `files/document.layer_scale.1_1/document.layer_scale.1_1.v2023.vwx` | `c1e03dc5987a8d1dfac6106c11be4742b54c857ec6be25accccf94f89f60b42c` | `0f2fee27b0c06c2f0665cf1115b8b6873d40b74bc540b72e66b6975850be92d5` | 7976 |
| `files/document.layer_scale.1_50/document.layer_scale.1_50.v2023.vwx` | `606b25f7a61fdd6edb67627d3d8411cf9860ce6b2c5116f7c801aeb14862db39` | `21aea9ed5831ac68a637d964c986a49906861e5e16a95eee92b66071e435475b` | 6098 |
| `files/document.origin.offset/document.origin.offset.v2023.vwx` | `91c968cbb19db1971849fa79c2a26ccc6f224c6be647f5129b5b5ae8152702e8` | `2c0037076f4a275d206e81a128de566f734308dd10cc19d637b67b3d1b9ed326` | 6833 |
| `files/document.units.cm/document.units.cm.v2023.vwx` | `6be4292d3eef3d2e2203de23fc23ec8ee4b76738024abc60a3c021928c5bb1c2` | `cc33bcc041346274d496e3b048e4e5a8693147f66c06725a7c6dcb907a0940df` | 5542 |
| `files/document.units.feet_inch/document.units.feet_inch.v2023.vwx` | `4589762e9d95751d1a08297b21f8e7153b79adf3d0f64a51ed7636e4ae22f34c` | `a5f1c3ad4f729c430978d5f78242da2ea457551475255965c0e9495e03b3d9e6` | 6166 |
| `files/document.units.inch/document.units.inch.v2023.vwx` | `6b1b7801b1eec0c99e36541a89833e7e9316d6cb234bcfb4831a686976b3389e` | `f06cfb71e6a4947f6ea79eef3dc0c78aa74ba16c95b33161b6b9d68f0c96c737` | 5946 |
| `files/document.units.m/document.units.m.v2023.vwx` | `8517e4eee26ca70ab569ed27a87955174aa0e2266258ff0b47f72a7991d4239b` | `b7378522fd02487f07dfb05535f53b776c555a992959d3ec952cbd6f04cab0dd` | 6857 |
| `files/document.units.mm/document.units.mm.v2023.vwx` | `099c9d9c5b795e6cc91ad4d8c0e0fc584016ef534988aa38eadd745bde81d7c9` | `c1982aaa209b916e70fffbb6d6135d7db70f32f2647aebdd7283fdfab3f67c19` | 6502 |
| `files/document.working_plane.tilted/document.working_plane.tilted.v2023.vwx` | `3ad8c30aec4c7b55eef0171acd51ad6f2c70b880bd09f8b9a4a82811aa8fea5d` | `ddecde5e5d97292b65a2669d7f94b866d306ac2c0831bf237e5a6872cddf1648` | 5272 |
| `files/entertainment.lighting_device.single/entertainment.lighting_device.single.v2023.vwx` | `e5deaf5a7da299db1a5a54edcf875f0bae82554c1337d21d97796133b9cbea0d` | `cc2a675b3d68cdc0982a8496b7915acd71bc0545aa0d6e6a69f8f6470720b8f6` | 5813 |
| `files/ix.mech.hybrid-2d-3d-class-override/ix.mech.hybrid-2d-3d-class-override.v2023.vwx` | `8ed39fb642a07c3091831297420da4303b25b6871889561081b025547970b833` | `33c67780f78ac9432ca20b5a1b8ee50071aae7a33da57acc5a05fd9c93265a85` | 5829 |
| `files/ix.mech.nested-reflected-elevated-hidden/ix.mech.nested-reflected-elevated-hidden.v2023.vwx` | `7a7b6d311971cec031c9807cf43c583085e3f696d58d41fcaf4572ca3ffcca7e` | `a198f28f51e2854097166e49b24872ada3c9308fc6d5f3107140aa403d8f7902` | 3915 |
| `files/ix.mech.rational-surface-trim-hole-units/ix.mech.rational-surface-trim-hole-units.v2023.vwx` | `3c394f5100368827fc984f107e847d958709f4c93b31e97f604a6b269fcb3fee` | `85106b2b36c17b38adf34660467891599950c567fe2bc32a40d8f11b4bb6b157` | 4916 |
| `files/ix.mech.repeated-shared-distinct-metadata/ix.mech.repeated-shared-distinct-metadata.v2023.vwx` | `3deef87dec4aa28803ede6be814c2f62323c6f81eed7b70f47c3077f8d75efc9` | `b4e3d9e55c2a9caba519ad334268f691b354a3ea89dbfa3638db691b815d5367` | 4418 |
| `files/ix.mech.viewport-crop-annotation-visibility/ix.mech.viewport-crop-annotation-visibility.v2023.vwx` | `9aefe8f608363f104fde068fd9a9266919c5605cdc068758643e9fc43d6cb8af` | `5dda2f11fc6ae447c59ed570de8777a055881366fc92730e50989eadb64ef2be` | 5570 |
| `files/ix.planar.08a344dc9f96/ix.planar.08a344dc9f96.v2023.vwx` | `b6936afc9cd45dce0b06de6a2bc66a970964dd2b04a9c9363d26a7660d8448fc` | `3425a453fd88b4a425554c52371e2db657550218e62fc2416138e25bfea265c9` | 4321 |
| `files/ix.planar.18e402f11398/ix.planar.18e402f11398.v2023.vwx` | `66f1c41443ef517b6e8bd3978a7024a841838a81f0eeb5ace468868101de55e7` | `1f22b404ccdae77658c39fb3eb5b6d7930477b636d901e7f6d743b3556428d51` | 4451 |
| `files/ix.planar.4c9fe9c05a47/ix.planar.4c9fe9c05a47.v2023.vwx` | `d72ed0b4112244175a0a5608928881f2af7d7079e7f00b6ca208f0b2abec0f80` | `e2662cea542cf6dd011e5539c129c628768f0963bdb56ad380d4a28d31e07171` | 4290 |
| `files/ix.planar.7108ea3f547f/ix.planar.7108ea3f547f.v2023.vwx` | `d4d059b5bfd58b6d1d5c4a4c5d87c0b16a4ee6ae972162ffa137d7ecd9146f57` | `66a51dc3f39300598e5c524e49e9033cbaeaba64faefebcc0f2a7e7578861dd7` | 5002 |
| `files/ix.planar.76a55dfa0e99/ix.planar.76a55dfa0e99.v2023.vwx` | `536cc8c2f093779a608804066d4579125cce3c50c89e99fb9fb9cc9d4bdb99cd` | `9f01940fb4583f035a58f74d900023d831c999ae807a69a461b9ce447ce29f79` | 7259 |
| `files/ix.planar.939badf6bd41/ix.planar.939badf6bd41.v2023.vwx` | `a2ae14e9360b9f8afda47c791ef1ed2c193696888d9dac93f66302f882c924a3` | `3e37376e997c4406bbf3c3228d0917452a22f9f6dcb0374ca0c6b3ca1cbf1cb9` | 6365 |
| `files/ix.planar.acdd57e27bec/ix.planar.acdd57e27bec.v2023.vwx` | `7e65e42fa1d7cbbf0adf835b20cabb32736d3ed9bd9dee3d237ec145e3d200d8` | `d8d0e44b8c668a53f3177618c7fe1202bc74429d0931a827fdff67d7079636ae` | 4041 |
| `files/ix.planar.b592862becd2/ix.planar.b592862becd2.v2023.vwx` | `35676e2ac78edb06ea42f24846a5c043f70531138376ffd302a5e27a8cf7ac7a` | `ddaae21890e2c8da99027a5b00319a35821e1eb4a59f1c775ae99a788a67fd6d` | 6344 |
| `files/ix.planar.b88144920570/ix.planar.b88144920570.v2023.vwx` | `a4615d7dee7a231fa7ca79912d263d60577f78b7babfbb64c3e89362107df808` | `6aeeab17ffaefdb5d21e6e950b07ceae7a1616b88cd7cc00ba953bf91b12a369` | 6599 |
| `files/ix.planar.c16429abac1c/ix.planar.c16429abac1c.v2023.vwx` | `253ba9a585a2b0edda1ce454093156937833663163857c753636120680f16f56` | `49a87aa4b692be787024b18d4a9238dc1da118559df3b4e05187c6e18f0e11f4` | 5128 |
| `files/ix.planar.d064e8d18eb2/ix.planar.d064e8d18eb2.v2023.vwx` | `8a263b6db84143780152d35c49ef705cffe8759631c5b0c87968c3d2c47814e8` | `a34cdb2bf357afe416a7c981c0e64c333ef98d7b0c146b374b6ca6a6b729e49a` | 6329 |
| `files/ix.spatial.156868e1946a/ix.spatial.156868e1946a.v2023.vwx` | `098116425085f801d9ffde6ccfafb2e07b008a061be4248e39e56d4030eab5d5` | `67651bcb02842586d925368951ddea4d6b9b657ab69f7b0988bc45eb4bdf60c8` | 5746 |
| `files/ix.spatial.162f3d3ad09e/ix.spatial.162f3d3ad09e.v2023.vwx` | `f9b7cc4339b5fc0a2d500e964135c1e4d2fc689086a3688d114f873bc2e8dc4a` | `b74582b2c98e22800564632b7682dea3f0eed73c544f8fb2d353ee4757a23d35` | 4576 |
| `files/ix.spatial.1a3ba3f36c82/ix.spatial.1a3ba3f36c82.v2023.vwx` | `e6a7ee298d03b9b36d9c8c220a986e79a104c4d3408fe08e6920a9d60842fca9` | `3d0ea8ff8d9e217660181e2941fd34b6fdcb7fa72ba2157155e8409631831f7a` | 7380 |
| `files/ix.spatial.479efd6c5e84/ix.spatial.479efd6c5e84.v2023.vwx` | `99c129a98e41c63329411ff8f2fed302bb17558100f8572fb9bfb222c21c5107` | `f34ee9202d8922804724d0fa8ad51cc13d0c8bf66d3cd7aeba8f17f83166eda2` | 5823 |
| `files/ix.spatial.6a273393b8fa/ix.spatial.6a273393b8fa.v2023.vwx` | `4c618411cb189a615c418b5ace6ac8b84062a6a16f10c815a789286c3cbd60b9` | `346b7bfba44e4b3e2faad17155fbccbeb17f3de60890e04a635cd4abef05b8aa` | 5163 |
| `files/ix.spatial.6f0844765639/ix.spatial.6f0844765639.v2023.vwx` | `da65d81b756fafe655ee6519d80229a41efb6ac1fb51066ba080c044a7d3c368` | `92ac024678e9dc5f2a222bfdc066959616731629d9c3a047187247dd3dbd1a18` | 6881 |
| `files/ix.spatial.7f9b5bd253be/ix.spatial.7f9b5bd253be.v2023.vwx` | `832ee4740e00c65206ed64d282dd2cc617e9ea9606722be65e079848ef617409` | `6ef324bad3709585e5213be7193546557dca15b879b2b61691ed06c3de2ff151` | 5410 |
| `files/ix.spatial.9f0fd0f5c94a/ix.spatial.9f0fd0f5c94a.v2023.vwx` | `6867d93d2a03a8e1f628e030b51dc4074993ed7dc308509a1050b596312951d4` | `525444248f7c315f379222b2db8088c48784b197cefad320d4af82cbff708494` | 3889 |
| `files/ix.spatial.ac39b9ac7ebb/ix.spatial.ac39b9ac7ebb.v2023.vwx` | `bfe8edd3b569f8da936b0849e8af25d403d5e2fca50416364843805023a32a88` | `8df69e47a79f99f2813ff4f08225e1daaedb5e72b98f99bae580042b64816b3f` | 5483 |
| `files/ix.spatial.d26473bbb730/ix.spatial.d26473bbb730.v2023.vwx` | `b013acc2b65aaea8413a8fecd4a5e2cf3ae266ca17ee803de086314ce8f08bed` | `5b395142b84ff4840b11cfbbb0fbdecb216836aa248a0dc1f8ec79e71acb275c` | 5245 |
| `files/landscape.plant.single/landscape.plant.single.v2023.vwx` | `29b3797a99598a3df788a107368254381900ad45956b142a8d2dfb67b25f3b23` | `16e9f911ed753dc2c4b27ea799308cee4bca6c4a5d2b99d72aa19a3724a51091` | 4304 |
| `files/nurbs.curve.cubic/nurbs.curve.cubic.v2023.vwx` | `64bcb123ba710e8678ca404258bef925d518b5e30b06ba5f48b7307db1b50351` | `b4e7d8a630a198a3611b55e6d22a4990b0e7deeb6f9d43331931137d56b2ebf2` | 5045 |
| `files/nurbs.from_conversion.extrude/nurbs.from_conversion.extrude.v2023.vwx` | `e37b469d5a494bccdc1ebe3e8ef470f429a7ee2b25fab0e024364225d36f767a` | `4e0fee0ba1b80921a39bc62cadb607cd206f60582488cb9e994d0ab06f87d583` | 3998 |
| `files/nurbs.loft.closed/nurbs.loft.closed.v2023.vwx` | `80b16e1e429eb22533d291013166eeea8293e9a980bda25c2bc629228126ef0e` | `9777752eee7774b35ea1f1cded4971a77dcbc7c3894a8ac8c84f959e64b5967f` | 7422 |
| `files/nurbs.surface.rational/nurbs.surface.rational.v2023.vwx` | `ccbe03166bb73b10eb6095699881de0011148a941c4664d39f72372048bd0b33` | `1595ec30b7471aa2eb9eab55747594854b342f2920dbf193b83b14b2a7c225d6` | 7160 |
| `files/option.linetype.complex/option.linetype.complex.v2023.vwx` | `5ae881e8233a68349d66b4fd6258df4b2f4fe04fa297eb206530887f81dbe0a8` | `8b5d00fa89e44c4cb670840e7fc2113fb6ea79a9ee782a84420004afd397c148` | 6635 |
| `files/planar.arc.asym/planar.arc.asym.v2023.vwx` | `fb34695b340be157928046ef5373437e3d8defba7e7a980a6081d7d5d19e5b0e` | `f40f196040b763b14d4bd180c62a446cd8c93b7babee5b22c34813d3b31715ff` | 3103 |
| `files/planar.line.asym/planar.line.asym.v2023.vwx` | `c3829bed90c358bed29ad93131ea67760522dade5b6898061c2ca0837fc0e4f8` | `64e9ba70872962a89a97fea9c7ae5c0400f823b9b7f67beb6aeece06bc3dd0b6` | 6636 |
| `files/planar.locus.asym/planar.locus.asym.v2023.vwx` | `7d1171889d0becbaa52220aa08fd6e5d95cccb1cb12ec5e00364b33dd0a9b4f9` | `2134e3e83ce6b49c0c6f4399c485356d7088bc17e86aa72f5533f6a4433d51a3` | 5090 |
| `files/planar.oval.asym/planar.oval.asym.v2023.vwx` | `cbbfd7a5785e7630fd5d7d0a85a6c52b9e5cfc910e412f4c97a8223585d08838` | `799c70a40e087894d2adf7d48972aa29f55f6b1684f694b05ab6366e009038ab` | 4051 |
| `files/planar.polygon.asym/planar.polygon.asym.v2023.vwx` | `153572a6f4e4f1981d30d35eb3c665970ecae141ac7542f8b63f98849ead21fe` | `055f4798e63b518ea5875ffa5da175ff0f98fc524140891cd10b11f1f363e636` | 6349 |
| `files/planar.polygon.from_polyline/planar.polygon.from_polyline.v2023.vwx` | `3f37f628f12dd32e994196c76170b4ff9865c82e20d8e0c25288a8aa30be0c03` | `d88c9dbb329970efe35258695a7e814e81aac11f19d90dfe27ba5c85ec37c93c` | 6533 |
| `files/planar.polyline.asym/planar.polyline.asym.v2023.vwx` | `0545351ee662a46c8edbe87b22111051e42b97fadbe42929ce90df6cf162b54e` | `a93bdbc29da7953a1112992edece073d3c98ee8e991717b00499c9995c632dc4` | 4199 |
| `files/planar.rect.asym/planar.rect.asym.v2022.vwx` | `ad380ec7a5be974490787b9b831659e578e54ed7a161a450d61bb3f4c40c72e8` | `74c25703323207545dabb85466f2126712ec1dc7559c0e4b3a647903048252c4` | 6527 |
| `files/planar.rect.asym/planar.rect.asym.v2023.vwx` | `1ea9324d78ae7e73b381e501a1aec79a980737f65d8524d94868168475381236` | `aaf0e3a99276ed0481b3661c43922aed5ba3f7ced29d5d2f30540292e55f24d4` | 6191 |
| `files/planar.rect.asym/planar.rect.asym.v2024.vwx` | `5e346bcbfef44f076aa7f3cdd34e16d109e92b99a1d18774006244233e4be643` | `dd37b580af5dceba480feca88c88e37f1cf4137c445b72ad344d7eebc5fb50f6` | 5505 |
| `files/planar.rect.asym/planar.rect.asym.v2025.vwx` | `27e020d362eb1fcc75d47a23cf2cf4dc47ebb62de520eac6890da2ad9cd579e2` | `3fdc01f534e31ba2db393cba056590ccbac393eb1515088f7255c5d032462589` | 6299 |
| `files/planar.rect.asym/planar.rect.asym.v2026.vwx` | `b50c75a436d2da474ab084c3345268785340f829b0239ed8017be742a5f3accb` | `eeb6324e9e0f4df49072726e82a2d028ddab0c0627ed929d2b73cb50ceb902ba` | 1819 |
| `files/planar.rrect.asym/planar.rrect.asym.v2023.vwx` | `1148bb85854921823c12bdaacc4fbb76f7513e05e2ae3663769e376ea9aa1f58` | `70d28c65741e5f2ac9625fb68b29b536766c318008045835b3d02aa24d4b6b7a` | 6327 |
| `files/plugin.combined.01/plugin.combined.01.v2023.vwx` | `dac1215665cefa9b3dbc8ee4be7b6e0487053ad75bdbf7430bf4ffe480f801a1` | `f49ab595aff10dd6a95c0bdea27ef74675acc71e8082fe9c68fb506f0ae016da` | 12179 |
| `files/plugin.combined.02/plugin.combined.02.v2023.vwx` | `832e67459fba7624e3064ae521ddf79dbdabfc1727a159a56bee88097ec8d20e` | `ea83256c8ab45a4713f36e307fd25f533ccdfb13e9dfb60088119e8bb33bcdf9` | 8843 |
| `files/plugin.combined.03/plugin.combined.03.v2023.vwx` | `d2f021acbab452006df93a8dbebb8f04909902caf1ccec0805375e016ebbb862` | `e4a822e830bc3de59f14543a1f235cdd06116d59d6f713feaf317026cd20d0b5` | 7411 |
| `files/plugin.combined.04/plugin.combined.04.v2023.vwx` | `4e268000f74ce040ab35a08e4ded8232233e572926bab80e78eca69686ad31b9` | `61712694b29bc5c6150c0d676307a3595241ea4a4dfbcc42d11454f6cc579e42` | 11360 |
| `files/plugin.combined.05a/plugin.combined.05a.v2023.vwx` | `d504b7ec4b14cc71b9dd287e302b1ab445332e8fadf62d37ac766c1ded9916e6` | `59e07bb9b131fb5c0b82a1f9fd1dc42db671fdee236bebce063fbf29dbe57f60` | 7473 |
| `files/plugin.combined.05ba/plugin.combined.05ba.v2023.vwx` | `04b7f2e8cc2608deb408e081ca0600fe7612e31f67c6fdd2371f383247773bed` | `f2e258463e68e4d000e31c2cfd033e3cd99bc3254ce4a6c709777bf472525c96` | 9668 |
| `files/plugin.combined.06/plugin.combined.06.v2023.vwx` | `c4a31fcd95562cddfe49e86eae953ae6f55f36dd6fde5618ea3c0ebcb0e72027` | `1ace4fc5c74414000580117c47d77592a607741f30e3fac2e2cc233b608fbf47` | 10778 |
| `files/plugin.combined.07/plugin.combined.07.v2023.vwx` | `89c08275762bff8cd776b1e7b039015b4f766fd59a2e8042b822a90ea45477c7` | `a266bcdcc4c6ebfe86d98d14b779ccb926ed1c4ed75052196ad3ad0429320b03` | 18761 |
| `files/plugin.combined.08/plugin.combined.08.v2023.vwx` | `667d9ceaaeea02cb5afd0eb6f09db65ddd047256c4478b87bc3f3df8e49acad4` | `7a1c3ffc950a483cdf4e08c07087e0b7e2fee602adf1ba63199b73f3e8038b46` | 16395 |
| `files/plugin.combined.09/plugin.combined.09.v2023.vwx` | `25f360c8aa1438dca28569f6754c96a1a3099c0a95bf96c3b685d2bc000563e9` | `19131e382fd11eb96e6fce27ecf77ccab716702917d80fcc93a779ee03996c21` | 22515 |
| `files/plugin.combined.10/plugin.combined.10.v2023.vwx` | `5c683fa96639628524433b9238bb9abc1882f0691f37ec9cc129e5891ec619c0` | `67e757fd27e92ff8205b97e45c99cb6e78200c94765a7015dbd3c476d56b9ada` | 21437 |
| `files/plugin.combined.11/plugin.combined.11.v2023.vwx` | `bde3059697ba19106c395eab2f140935707aa3ac0ff10238a070719f1849ad96` | `1b5adc75b8fe338c300774436612828b3e9a6120a1a8784753e74cf1e0875c03` | 17275 |
| `files/plugin.combined.12/plugin.combined.12.v2023.vwx` | `0bc4b02aecb81492ac1dfac77c0cff1791fd2573677359da207eb59d37bd39a6` | `cbec9b07c0acaa26402079752e71126334e3596e35acbbb5c1ddbd1dc5c61863` | 16893 |
| `files/plugin.combined.13/plugin.combined.13.v2023.vwx` | `16e935fe889246191dab6d06e5d01a0f30f55e01fffbc429f398f0b260bb9d35` | `9141531d2f8b6d3f246014fccf80d83679034cd5a59f76598dc4be313413c8d0` | 21022 |
| `files/plugin.combined.14/plugin.combined.14.v2023.vwx` | `ec88e043f96f96750201b8d0b19f9b431b37999dcfbb67cc15c2b39db0fad0fc` | `10ef5b2d5b3450d6d2f2560c27ee987c3c448ea6cbde1684f40bdb80a188fd41` | 17719 |
| `files/resource.class.attributes/resource.class.attributes.v2023.vwx` | `65655e08d067b85171080e1f7e2d1c791897945472c543bd5c5cfd3819f89e30` | `2953084dba85a50bff1c83ab152b4e14d9c3fc22748ebb0c8688039bad7ae90e` | 5957 |
| `files/resource.class.visibility/resource.class.visibility.v2023.vwx` | `b54c3d4820edba8feeef947bb84a9c75516e9647775cfe64321918ee44490432` | `3e4162f14a3c984c90e8d03e516a8ef01612be8b8031be3693b99dae12785df2` | 5553 |
| `files/resource.folder.symbol/resource.folder.symbol.v2023.vwx` | `b74c3647144e2cf86038bc15425db6857b0d9d7662fb87718ad02d1ebc7e72fb` | `3209f993bc64e08df173a00c28d1b692f7de7a3019416fe84e9317b1a4edb009` | 6010 |
| `files/resource.gradient.three_stop/resource.gradient.three_stop.v2023.vwx` | `fcdd0933fa9b14ed0a6283a5cb9ea72427c34129b5c2baa9d9a806ca057a8f8a` | `578acfe867a5e509866717fb51b67082770bcb5a46dd9d0b5cb51be383881720` | 4686 |
| `files/resource.hatch.placed/resource.hatch.placed.v2023.vwx` | `ff319b04f34bb05fe736deab06940ee511f326b0e29ccfe8881aadad91b489ee` | `21c68c8daa54a82b95c2bc47f13d9f6a59f40f90a5c14202d168e6409bbfe0ec` | 6719 |
| `files/resource.hatch.two_layer/resource.hatch.two_layer.v2022.vwx` | `41e8d49c23296c65110118f2cb74af51a217ff84bd3a0a2c8c60503822daf77c` | `d944b7a4054f953ebe2470fee01a614f199db504aa87a88fe0e87a2e22774cfb` | 6797 |
| `files/resource.hatch.two_layer/resource.hatch.two_layer.v2023.vwx` | `eff3ddb510f9fa74912749653a1b7f5b18df834b5e83233affd25c27e7a979c3` | `ab1e20b145817381d30fb3a411b10fc85e37ffcbd6c754164dcc3751d62f291b` | 4367 |
| `files/resource.hatch.two_layer/resource.hatch.two_layer.v2024.vwx` | `ccb2b3e4409ec180f26bd418dd5b772aff3ea928f6a53ed6b2b21a702a9e6809` | `a9a4da3bcb2086d2becf2c689d114e9a7e76c8699698f6556ea6a4bc5dda613a` | 5001 |
| `files/resource.hatch.two_layer/resource.hatch.two_layer.v2025.vwx` | `fa90d95a6cf7d6eef4d1d080baed171831d71cd0763097be2b1b6e23ccf8ab5a` | `afe7bbc778af267cf7faa6f4d1ff53ca3aae5e3431de2e6be3b74096be1bb39a` | 5892 |
| `files/resource.hatch.two_layer/resource.hatch.two_layer.v2026.vwx` | `7d8a93efb0a40f43689251b3b251f29fb91cf85f3d2abb66dc6c1c09a0f117ec` | `f2d1afab974914bf1341b6a526005ee25d5796ee1e8393828fe4043e031d019d` | 1819 |
| `files/resource.linetype.dashed/resource.linetype.dashed.v2023.vwx` | `6bc20f5c55c847d6ba8feb30bbde9b3e56c51d4be2aaf830e87840e1de7d8734` | `15483b25ad192be8d68a36df4747d9a4d5d0d0e7f89e25b11e6f738c55121d73` | 5883 |
| `files/resource.material.simple/resource.material.simple.v2023.vwx` | `90599eef0476204478ffeae042863a7f215a09a6c56bbfc5ce84e299bbfe43dd` | `e3ea641b23bb2b92dc3402d60d247eebb6b55abb3d067f58e11dedf3584e64e7` | 6296 |
| `files/resource.record.attached/resource.record.attached.v2023.vwx` | `d5cb154074ddd166565d8e0a4096c0ee55a725d95670762cea7b8d9b03f28525` | `6c90312fba996d4f65da684e48c7bba9c1768335ce8a72292f24bc77de9e8673` | 7216 |
| `files/resource.slab_style.named/resource.slab_style.named.v2023.vwx` | `b42cd7a2172aa023117b5d3c5fb19b4c1be39e278ca9b5460e99e2fa565d1e89` | `cb786007aa39c55019e0c417e8f416ea46b5efb5888ce8a0b1e5d8c88ee0c251` | 5097 |
| `files/resource.text_style.applied/resource.text_style.applied.v2023.vwx` | `c68aca0f6ab0c1051fd22f385052a8e32d9e93f85c1f3f07518f655c7c41be9f` | `7364277a49885b945fc090649e9c1f17999acb46673fa0a23f3c5087a7138720` | 5546 |
| `files/resource.wall_style.named/resource.wall_style.named.v2023.vwx` | `fa09609566d9bc06575da07d371373f51f698ec1b685ef60ab214816381d1c19` | `701422e972edd934a8e5b0d240821be13da82679cd94fd1b889508db49bc1fdf` | 3915 |
| `files/solid.cone.asym/solid.cone.asym.v2023.vwx` | `de8b36b7ddd4a0797a4d56691f860a44203f5daf6fcad2e30afb9564e1e2c176` | `6a65c92cc413be945db29579e412fba37000574f24d31b490ad196ef8d1eae6f` | 5348 |
| `files/solid.csg.add/solid.csg.add.v2023.vwx` | `cf49112513ecb139138ee1458ab9ac2a089abacc4c623766021eeee7f76afe43` | `39956398705a7b1d63a344c3ecca9411e4f6b5279f5aba78031478367f7b5596` | 5479 |
| `files/solid.csg.intersect/solid.csg.intersect.v2023.vwx` | `3f099fbfd5296a7d31b8df3615e2f6bfcd3b1a77f012f759ac39dcfe75cbad23` | `b9a6726992e1f19335672e092c00652c92d644e7e3313d3aef222e5704b0e64b` | 6816 |
| `files/solid.csg.subtract/solid.csg.subtract.v2023.vwx` | `3419d8d8998491139005682232827552c3590c9bc5a027c8723f9787a85f888c` | `80d92102371c0963e435be4adafa7194008ee2f29ab26e93af9fd0cae15a811e` | 4717 |
| `files/solid.cylinder.subtract_sphere/solid.cylinder.subtract_sphere.v2023.vwx` | `c11d11d62aa5ab513152b6b1775f98fa4d6fa8ad58b9942a0bed1ddfe5eff263` | `f8b6e72062a90262a921c5d63c2da670f786de0a358123c38c549470c7652fca` | 6737 |
| `files/solid.extrude.circle/solid.extrude.circle.v2023.vwx` | `e51eb303ecc7c3e1b898934374ad73833301dfe2821fca5d277f21530e095121` | `b9447230be3453a0fb6e102312cfa71c1920258651df6204a8bbad657f51c8ff` | 7062 |
| `files/solid.generic.from_csg/solid.generic.from_csg.v2023.vwx` | `73384afdb830eefa353ff216a13f616e575d523140d0430432ddb92670d80627` | `6bef1ccd734d08fb6f3feb32691f2f5b046fcc78c2f6757b9d27bff067317046` | 5561 |
| `files/solid.hemisphere.tilted/solid.hemisphere.tilted.v2023.vwx` | `73e9b7657f7a16ff1625237b3e49187799ad85a08c26b8c4d099be1691f649ae` | `6ade901f8d8ac56241d3ad64a367e610280a3ec9c75545454db3d9463b47053d` | 5114 |
| `files/solid.shell.dome/solid.shell.dome.v2023.vwx` | `ac09cc35fed53f8501db431d410d0573aa7994a4d5ec286ac055c4f652c71095` | `a9cc46e1b8912431b0ab7bf856908064bebc2ac76873ef3ce6206a02882c4b30` | 6083 |
| `files/solid.shell.surface/solid.shell.surface.v2023.vwx` | `15bb5939df4b3dbe2602281b52b8defbac7462c1d4c07ee9cf6ea30eb8000165` | `677887b20e075a249ba88c038ae20a18b65321c7090931fc9a115d63c9462ad1` | 6495 |
| `files/solid.sphere.offset/solid.sphere.offset.v2023.vwx` | `a557c7f92f2041de8fec59018d4bc429697a3c8eb842197a5845945cb33f7354` | `89c49a331e0be5d8f24a3f02c653d6a69e91e2a7cf3dbfafa30a9cf59c1bf1b0` | 4883 |
| `files/solid.sphere.union_offset/solid.sphere.union_offset.v2023.vwx` | `7423d495efb7e24438bdd21af4c2f6b9274ecede79b4b68e03dc2e53980dbba3` | `50859804db0454c57e5befabaa345c6625d2d2fbe23e9884080a84f01a26e453` | 7988 |
| `files/solid.sweep.circle/solid.sweep.circle.v2023.vwx` | `24fe0822085632c2200f5144c379bed7fe38c52003dd5cae02875a3cc16de1dc` | `03eb330512c918e10046fba0e3e0bf74675b89a518600a2b8bafeac16fb92670` | 5906 |
| `files/solid.tapered_extrude.circle/solid.tapered_extrude.circle.v2023.vwx` | `2bde2f1c542a20f4fef6644fcd0d80b353c2c525186943fa39877a992a2f5f4c` | `8670456c6431193530f601633d430f84c464883038d8c75db97365a7b8e968e3` | 9282 |
| `files/spatial.extrude.asym/spatial.extrude.asym.v2022.vwx` | `568bf5f1a794a8c5d5bdeacccf064ad31876527df5529260d88a9ca99206c42f` | `68be68c46374b8a3659fd6215ad4ba72744f3d26db540103e84f05fccba9022f` | 7277 |
| `files/spatial.extrude.asym/spatial.extrude.asym.v2023.vwx` | `d77e032555c967f434e754f1dab136621cd345bc19160c4cca6bc7e5f1b6e170` | `454d207a20aa1095300b0af9fe2f371be15d6a121394b7602496767f89c3fa97` | 3864 |
| `files/spatial.extrude.asym/spatial.extrude.asym.v2024.vwx` | `9a3ef84d3605e34e9bf5702f06bc6f3b39f97047829f328af80a8d35302a9127` | `63e547c90ef83fd7c3853b330013489c0fdb66636e925736de8f0e8df2b911f8` | 4438 |
| `files/spatial.extrude.asym/spatial.extrude.asym.v2025.vwx` | `a5abe7fbf1d9dc914e22e8286f596fa26600945b0d0dae8b65a888b4d61fbaa1` | `71b6eeb2fbab626fdfadace2d157430a7660103403196af8d9bafa191d7e14b9` | 5003 |
| `files/spatial.extrude.asym/spatial.extrude.asym.v2026.vwx` | `f02b4fdffaeca02f6bceffd496248055e8adf7e151564a4008c8c94258e39db1` | `7be8f28aa3129472c7362c86b55ac3b4c99f2b876dd7abac6dc81bbccc6c333f` | 1819 |
| `files/spatial.light.point/spatial.light.point.v2023.vwx` | `45a588726c2abaa3fba362ac68bb93eeaa997d4342907426ac992d709cfd3b38` | `b73add8b57c2faa25d1286837f88438fa0dbc4a58c8f691370988a38992655c4` | 3991 |
| `files/spatial.locus3d.asym/spatial.locus3d.asym.v2023.vwx` | `28102f4db1716affe3476f0104743c1ee854d463321f7a37c50afb91daa69b3a` | `66ca71f94f2b90043869edae1c1037c1765d5ffd05a1591fca5255b79c3d5fbf` | 4796 |
| `files/spatial.mesh.from_group/spatial.mesh.from_group.v2023.vwx` | `04f13f80ba7be2ff4fab1f6557aba0db2d1572ccab1fe2bfe47e59c7d7b6a147` | `ac142496a8831f4c66fcaee7b5342a6397e3abb6badf23a94f8fa6b48acd7c99` | 3663 |
| `files/spatial.mesh.tetra/spatial.mesh.tetra.v2023.vwx` | `52c2847fc782d88fb895e242a4774d214085fdfc3168bd131ccb8a1ae1fc52ce` | `ba05ce6449f25b8d9812b76f233762672fe0916086dcd57b622c5f178aeec16e` | 3969 |
| `files/spatial.mxtrd.asym/spatial.mxtrd.asym.v2023.vwx` | `8071a5f8ade22121afe648523658c1e40cce68cc25567d692a888c619bd982e7` | `fb8accfdcc0cb939e366ba740da28eed1c25fddd3c9fc99a0650722a5aaa5291` | 5922 |
| `files/spatial.poly3d.asym/spatial.poly3d.asym.v2023.vwx` | `2c12d6e8f82349a60a7867dfdb8fd9baa084673390719218fdc5060e3b53a18b` | `9154bb27c57b392c260775589a74cc59b453d9b8784ab236c7c52ff7b90c7576` | 5793 |
| `files/spatial.sweep.asym/spatial.sweep.asym.v2023.vwx` | `f637f1972c01fd7dcc9ba9e2f0e8d127b9dec967818ab1f6ddf2fa47e32f35bd` | `89c2829551b068175da4cfba653183486f570dc4fcf5c71ff39f5280337b0b62` | 6095 |
| `sources/annotation.bitmap.asym.vwx` | `0946a3236a8a917959422329e01bb9f97cfa29d695d7b0c8d05ee308f92ac0c9` | `6a2eeb56e94395abcfbd269e8081e2aab8864eba6c7e4ad9d0d2a78a58235f31` | 1819 |
| `sources/annotation.bitmap.rotated_cropped.vwx` | `01d34418a71ae7395195dd4190624aad500cdf42eaafbf4f125ff2f0454d4547` | `3f2a37993d9062733dbd9f5eed9ba3faaf2a43b92f02b4aeed6c1eecbb53edd2` | 1819 |
| `sources/annotation.callout.single.vwx` | `10e77fb999fe09b398379f873da036cfa367f0ea8a6aed3dbe6b02156835bcc9` | `e63633e29e51c6641757ade6070aee9bc64a4d1e92dac0dc810a0e3383aee064` | 5369 |
| `sources/annotation.dimension.angular.vwx` | `ec9f40f5009d786b3ded424518b0cc5c6e2e274872d0f792eb07d07ec21dafbe` | `6ee15c7a6c6e1335964ffb20753e09bb2b636c30a9966be0c779341c0031d11d` | 1819 |
| `sources/annotation.dimension.associative.vwx` | `41aea4a56c3f8a54446eff00b0707f016161f1c1227f2dcb9190f22b4e945af8` | `b22e38588cd0467ae44ef4a264c2859cac304968a88d9e6e88152c85077622ef` | 1819 |
| `sources/annotation.dimension.linear.vwx` | `133ac35de5a936de8d09e56cf45c2e0f0a19540470071637ebc8fed2834f198c` | `f4ba105279a3bec91d31896e0ce6952136beaa956922257f5167d72b511b215d` | 1819 |
| `sources/annotation.dimension.radial.vwx` | `f8a947551a2384ec8e921d0c0764d38e741b5c683ea4fec6e769265469c97917` | `5fd7fffe28ac71dfef6a736f5d135f1d82baf400eb209628d95de1624deb0b09` | 1819 |
| `sources/annotation.dimension.standard.vwx` | `5e00dd1084bf04bcd1f964a1efa75258e6526fe4f397bba361bfb4a8c636c57a` | `8fe483586c8017c18e1eb0e47a9a104341cd5113c14fe2233cb241a81c97dc21` | 1819 |
| `sources/annotation.dimension.units_1_1.cm.vwx` | `68ce191c43942effb69fdf22adcaefe7ad9d18047c4c70acddacdcbf7419fdc6` | `f6f57f45c57c931ab78d8da0fb00773c77bd77a5f95dcf75e7a82c43398565b2` | 1819 |
| `sources/annotation.dimension.units_1_1.feet_inch.vwx` | `a1c4dc94bda4383bee17a4cd5b09b6ebab579c1359d86e064c000668d2756594` | `1acfff9f59b051f0d67cf63efe08e7bd0b57b2f5f9ff7d39fd5d0a5747711cbf` | 1819 |
| `sources/annotation.dimension.units_1_1.inch.vwx` | `d1491de092831ed0bb3f4ee687daf028dc15179d1b27a4b27a35d8250eae2414` | `58884e8482a2addcb4461dcefcda26dc3ac3ffd9bf0deb592cf39c452067d8f3` | 1819 |
| `sources/annotation.dimension.units_1_1.mm.vwx` | `129e2ba5992318cd44ff8a7fa088906fb19c8f3b3557e577152ec869be105776` | `492c3551b0d1022fb1dfabed7ce63af8709f02fa840ee55dd69f5db4a4fa4fbc` | 1819 |
| `sources/annotation.dimension.units_1_1.m.vwx` | `2234872ca35ed894a07f0739e4ae0584b2b303d92c6f5a3599154d73970e5c52` | `67233c32343b160bfe3bc5d70d98b1c1d6f7361e0364cfb9c87bc01b2a96731b` | 1819 |
| `sources/annotation.sheet.multiple.vwx` | `25c1d56c7b31d465b05cbf6040f139315d40ec2e223289180864d3105ed18a40` | `a7f9a4a85791d31a77e302901c50bdf9e7c479d4156197e6aa417428b8cb8b62` | 1819 |
| `sources/annotation.text.asym.vwx` | `48f1131c0b89b2f560c929e54acb209d940774f4f2cf5a7f03b7970362dbafcc` | `fdf19f447113e048e294c184951db6b5131767ffded3c3af04ad5f81363ff695` | 1819 |
| `sources/annotation.text.multiline_styled.vwx` | `43405301e8df00059cecd0680a273abb79115f85115df28a40bdae13dcf9776d` | `5723e7c6e9b5bf428911729dec8c7f9c842b14b37096d8b7dd9a89d842c01f42` | 1819 |
| `sources/annotation.title_block.single.vwx` | `1d81398a39aab2c2ba33530105d5b5acb654264519cb0dd1ff3faac27e5f0b87` | `a4ddc8ed1e26dc844a1f545d86d0eb3f63adc1347a35a3bc30b06439d26b8899` | 4075 |
| `sources/annotation.viewport.elevation.vwx` | `212af304ea43d3e1f629b983a991fc51c5c023e750d7f33b8a658c7e79ecf64e` | `b3aeb56ae49410e270ae74c731368f65cbc3454fa54c8c2b55bcebc6b7c3f789` | 1819 |
| `sources/annotation.viewport.hidden_line.vwx` | `f2736a2e8a5b60cc7089c4ed582bb12a99032bb80b436bb4bd4946b5ad4fa3f7` | `f2621766e3d8d2cbee415027b76b6639931848e710e1f213a3d101b4bc1031aa` | 1819 |
| `sources/annotation.viewport.sheet.vwx` | `589efecc9d81ccd028d353f2381f6d42868c73cb86e5c3d6d7e6f5f6cf423887` | `32e37c9735172d677306a68da9b3315af042477ca40695014fc38dc20f38a815` | 1819 |
| `sources/annotation.worksheet.database.vwx` | `441473200322a1c1dc62e78ee70cd1b216dfb33064d27ae1ff3636371c193c33` | `9ebdd3ffdb9040181a1279474a4011d2121c16ca0039940d63b7b7cf568790a6` | 1819 |
| `sources/annotation.worksheet.formula.vwx` | `35e759418c57f03120b8dc28b368edaf28114ccd80baaa5c7d7ccad550cbb87e` | `f5ee70d820787543dcbe98213c7f215fb5119c15189cb6ea8f86a649bdddac30` | 1819 |
| `sources/building.column.free.vwx` | `56982b6e5298f3fb3d866f1aa5279bffd6c528f7b831bfaffead8ebfcde8c01b` | `3868de7ee449b7569c9881611c3a64de553c1d8505b18d197384cf5d32d66318` | 6069 |
| `sources/building.curtain_wall.straight.vwx` | `292898e230f2b3ab1ae8c75bb0fc198cbd1d95596343c8ea999bfefdd80e883c` | `bf2a2d4a9586263e494a1e22bfd90e6cfed1f611569ed86f8c31f54e5eed7c30` | 1819 |
| `sources/building.door.free.vwx` | `e5361e099ed7800ad28f31d4a78465c5a8fd09758cb016e4b0c1822165b4a135` | `f1c08f80a6985ad3a66cca977cdb4cb99946af833473320eed02a6e7de04eeca` | 16600 |
| `sources/building.roof_face.single.vwx` | `05835b4955b8589eee112f59a376e86b98ff72fc538c5b68dee1f84201e58eb8` | `03cffcbe8cf67d365542f9c2e740a52392dba5399b0b7c952b4c6563389ec2ef` | 1819 |
| `sources/building.roof.hip.vwx` | `9bf4ee7197d55d9d9586bfd81cfc490eb97c17c080bf94f11284a244723eccd5` | `76e759bf0587ec3f9e4a29d085853dc8d77e4adc1881065604ec591b4de4cea0` | 1819 |
| `sources/building.roof.two_edges.vwx` | `d98dc083ecfa6a87b2d5c34586c6cdde3f8c40182bec4bc5ba78288321a26b22` | `7ee740dfb5f7206deb598cb0fc6bfcda745565199d69a51b78659a6a2fc469c7` | 1819 |
| `sources/building.site_model.points.vwx` | `08f9dac9ec9f7a5b1398a53c400ab044f16a2b6a7045fe963a1b0e1394f742ea` | `fdb45d7bdf7cb0c65186602d0dbe05bc013358bab80831643379e6f0749bc1f9` | 3576 |
| `sources/building.slab.profile.vwx` | `57a31bccd991caf1923cd64d3b1052eb5c153bcb347a7ba0a3bbf8412ab9ad92` | `4809610eabd4ceae3ee730556335175dfb6646b8c1b677bb6d55183c284f23e9` | 1819 |
| `sources/building.space.rect.vwx` | `d8e8305cdc0dc466b8d56bb32f221727505334541be93e68864d5efc64776057` | `abb1e5cd4ffafff46b164b811158087d6b2e1792825f99dfe19617f4b4d48e0d` | 16340 |
| `sources/building.stair.custom.vwx` | `d435e6908775961ddd7f50429e5583b55d3a34abe8d68b91821e8ab1e7190fce` | `04040269d0a871289d47121698d80d667720b6fd047e16176cf028e49b32d64c` | 1819 |
| `sources/building.stair.simple.vwx` | `a6bb7da848f0069242e60c8e7521de14cbcf272187a18ba700aa5373a39fbb15` | `a246f3dce97179ad2b305a3a64d16502f4c308ada953799eeec91ed4fd4b5427` | 9467 |
| `sources/building.wall.curved.vwx` | `99bf3fa977de9abfcaafb8567ac3cf2510b1a772b1620e19275bec84c5836cae` | `b20cfd25f6a10252f31f8233f49363a40e9863eb1282ea89c88de4e1267b83a7` | 1819 |
| `sources/building.wall.joined_l_t.vwx` | `bdc16f96fe10db3c9346d65f610c0756dd5decadf21553b82e24ae1996351776` | `2329c93ebb0b38b9b74d06c01c7bff95e3b2060cfd321cc526dd224476a7d5e4` | 1819 |
| `sources/building.wall.straight.vwx` | `3a46ec0cb9c1b31dea409ed186a9c02b438d767d5662fa781f450969b1fc8841` | `b868506449f1ac7e65dd6603d4ebba183f95b5b337de279a30f3d38a4a9e2ae9` | 1819 |
| `sources/building.wall.with_door_window_plugins.vwx` | `a83386e85f0121c8a469ced5bc3a512620463397558332479c8ffeccea3449d4` | `cd000f5efcf4a3c690d1201d6d9af48d33ebe1bfdea447b2a925e7858af4d603` | 55329 |
| `sources/building.wall.with_door_window.vwx` | `5b43f0ad77cdc6a34c3c6f847f7e27ab714eedc280394a81c1b3bc3f1a0a8be4` | `a395322d17e17ed0bba0a933ab22ed035aebbfca474122614f4144c2429e5eb8` | 68948 |
| `sources/building.window.free.vwx` | `b64b4de179cafa201e970f3c663f7282012dc52002492f97ac0449be57a553dc` | `69a0b831e1a658acfec749724fda2ccedce29547e0b6b4f159a717f5c94b9c08` | 28108 |
| `sources/container.group.asym.vwx` | `34c8248b8e48c6f07b6eea3f7a31665d92a3fb6e2bdaed0653a0f063083f8790` | `ce98bc6942ffbffb444aa77bbe55c88f833175b27d4e072dcc67594badce218a` | 1819 |
| `sources/container.group.hidden_class_member_visible.vwx` | `fe66c8927f31261312e7cb74bbf8ad2dc4247fd00951d212293be98b2e871b8a` | `aa57f54fcb8adba46f98a73b231fd66a25496e449f5c8da4fe121dc85b8ebe12` | 1819 |
| `sources/container.layer.design_elevated.vwx` | `bc8ac28f21c4b2a0990db3becb01713ae34a603d37446eefe16c38d7d99f6f23` | `d69a9c89d8d2fdc01c63e6b794e54083d98a5b05bad7b67c591632486c1fb128` | 1819 |
| `sources/container.layer.frames_base.vwx` | `355de8a2860bfb6848ba9e12701368d31097e8f6817ec4a4d3fac93cd433961a` | `f7c61bbdb65eeddabc327781b5113ee38f30061462ace8b60372699a0c4e80f4` | 2529 |
| `sources/container.layer.frames_iso.vwx` | `ca428950e17bb1df46966a120dac0e7b80644895a30e1a8507d9695e9691b256` | `9ee372fe58f2ff098343169491bacb41f28ff79f404ca466f9b398a76fa9464c` | 2564 |
| `sources/container.layer.hidden_design.vwx` | `96d22b9c1eb44844b945516b50979fc314419274515eb3b0b4727263d3f1fa02` | `3a400423c83c10901015431c072f40045e971887289912bb1d1bc54b43cfe69f` | 1819 |
| `sources/container.layer_link.design.vwx` | `11be77afefbdb9582ce68b5c09e742c7e15a3d8fa43b81ba9be860fe2b73011b` | `99b472e8b20837c4d1fc0e5ce34be575e692bf3335d7d4dbfb66b17262985cd7` | 1819 |
| `sources/container.layer.sheet_hidden_class.vwx` | `2fb1fcef26c6a881076313a725a459f2586030e914380818a17bc1f8e0ed0f2d` | `1206835c0447cab3ad8e32a43378dd62c53947104faedc59316e7ac2fd907273` | 1819 |
| `sources/container.symbol.def_instance.vwx` | `c6d8b68dcc59bf877fc4572a6819c53bae6a91df0587a2bac26aeb3d4ec58544` | `3905c7138c935a58a87a3c77b42017bbd22c81ea8b3460ff841ae100a20b2eeb` | 1819 |
| `sources/container.symbol.hidden_class_2d.vwx` | `1881c2d0961a760bfd10348da7a450d0dfc19213c84c3f34c816505f9873e011` | `8fee0d797d7bfb1d9ae881cb52b11bb9c38978c4ba255e1912c0c54a00426339` | 1819 |
| `sources/container.symbol.hidden_class_3d.vwx` | `e6337943c8daa5f21321c4930845c85c997e1162a8aa531f50996c48ea0f5997` | `fd3ac7729c25541c0c4ef0e9b6f6c60019caf181f25348fecc90f1ab71faf17b` | 1819 |
| `sources/container.symbol.hybrid_hidden_2d.vwx` | `db09c7bf3c109238e1fdbfc4d2a957ed09ee195eed94305d52663834a1b37196` | `2e8a367b193fe3d3ef64567697e80b3afbe6c1b93c233e70ff18f2b2c0b0d546` | 1819 |
| `sources/container.symbol.mirror_3d.vwx` | `f42407e73c3979fb1f8fe4a5e765f680b06d62edf9ff6934264d5af1068d369c` | `74773bbf55421fbffa95c8fffff725bdcd2c68b686b53692d2e9f6a972ac13b7` | 1819 |
| `sources/container.symbol.nested_3d.vwx` | `4e721d131f52ed46e6acfe2ebe3b02ca6865adcc4571c7a7708ca74a4ebf6f29` | `40b4fe93cbec1459a3028da488f2eecc8af743c9ee951cf4d8e8095df924e68f` | 1819 |
| `sources/container.symbol.nested.vwx` | `51dbba667407d6d12b3233789e7030043e14f88f4805165fbbc50ff30a82bff9` | `65dab2db2a6d739ec0dc2418c0e29593b0fba2b7c9ccd4699d1874e72b3c1264` | 1819 |
| `sources/control.blank.imperial.vwx` | `ad248dfe4a5ac955604311f61f61d6708a48d15949eb66d07ca96b25e602a143` | `cebd7017bc2b0fca7a28538cb06a46ac536bd69a66f1beba844e934882a88dca` | 1819 |
| `sources/control.blank.mm.vwx` | `a199e6811d5157ca87f3d39ad5c879e6d439e5554747cc01fd5da8b075947f43` | `7e7b8e88121ccd2b3a8d492eb4e1250e9992950a93aaa80e29b89171d791dd67` | 1819 |
| `sources/document.georeference.epsg.vwx` | `5f20b35cc5aabe5d3a5ba3a200c481954f42fe4cbc9e9f1ebb5b6a74c7593620` | `f7acc507771df4bad2dc376e6ac6378e3671345fee261f3c25e5f5983465b311` | 1819 |
| `sources/document.layer_scale.1_100.vwx` | `864ccb59785099d03ab127b4466facd4063d0c9e97f0905cf2c79bf1a0f0cba3` | `2ea2912dacd80767a1bd9cf6fd0b36a927bd7e09757f381940d43690833f48d1` | 1819 |
| `sources/document.layer_scale.1_1.vwx` | `8a1f7a70b2bb6c376ab0eaf7c5769351bcb666f3ab425c6bf38e8a6fee9c9bec` | `b15bb0f057ac0b78a5566a8a8aca123355b5032922735bb241eb84cce1446776` | 1819 |
| `sources/document.layer_scale.1_50.vwx` | `87f2811c044afd726a6ee2cd39cace4e4063227b6dc7c77ae0373bab7b10790a` | `43e4c85a70d03be8c2926896db3e757e8d45853b4ea6236752d82ad6e15fb2f0` | 1819 |
| `sources/document.origin.offset.vwx` | `23192490ecd40c79b4dd1941193cda17832b28e6434127c08eadc16a7fe60606` | `4f80acb73f34eac082abc801962a0a185c3bcbfa4b2c2349e3894cc22bfbd3a1` | 1819 |
| `sources/document.polybreak.vwx` | `4cfba86a7cd4accd41d79f1c94ffa3aed16b2f5f20537ba887da8dde71e0fc3c` | `605fa2e4a82492b965f84e5d6e2de486bbe6e6635b534e885c2c92736a02a364` | 1819 |
| `sources/document.saved_view.named.vwx` | `81d874439f8628d12fd6fb2c9479016f44274f60cdd170cbd6364e144a02ec4b` | `042d4061d1a9eae38ab11c21eb4483a4ad10938d861b2d13d32b9fcc78390a99` | 1819 |
| `sources/document.units.cm.vwx` | `98c25943fcf49073d8450e0c9d043cc3c61ae28946d06472cb38d7d149a882d0` | `a85be27904a50340cf548ea4c631db264a405fa65328a6ee113e8fb41faa3250` | 1819 |
| `sources/document.units.feet_inch.vwx` | `6c06615b1ace8b049729215764420fed881c421c532596a280d46d6b3ef5412f` | `4a6504f5157fc1b2cb9ea3c46c30b9b8685b7b532a490207ee694b5758d3d797` | 1819 |
| `sources/document.units.inch.vwx` | `001c4fab98d04a448a4e32fdc5cdf3a90f0aeae2b0099c131e28ac1ac8e9021b` | `c99e22eb2c16232ed49dad581e1abc20f5e7c3baf1ec3ff2699f8003259d0446` | 1819 |
| `sources/document.units.mm.vwx` | `1201a4e62f9bc0c520fd75428f3ac393191f54a9d7ba5ba85f1ec06c56051560` | `494c425ca65a858cf5471431172710ceb6cc51cde7bc5b70625e75ba55e315e1` | 1819 |
| `sources/document.units.m.vwx` | `96574c841ca1f975776f3973b939a89a3415962779da690ecf40f383999042d2` | `af8081ced2424a93af355c31834a3861ec1a82fbe6d63e31330163950fe698b9` | 1819 |
| `sources/document.working_plane.tilted.vwx` | `b2790e992032d09be35e93c091670414026e29a20cb49486e7b7776a7fa9b6bb` | `01241d2b4bd390a67edaf1a920ab0af2288b2ab492c3325fe2f4c0c91ce58d91` | 1819 |
| `sources/entertainment.lighting_device.plugin.vwx` | `ad04312597b6542070ab15afe995bb5f19b6c68af12856145123553117e0632c` | `06e15bedd3a994a9b262f378d6f2a6b36c93e87ca4296582c2f947b633c6525d` | 1819 |
| `sources/entertainment.lighting_device.single.vwx` | `30358d1e29d1f82cb3cfdce58d3b44297319775ccb6e97bde08858e1993edfbe` | `cfa4f7e0b656323c272a3e06beef8b31fcdcb9cec5e07afc8be08e4d0b5233fd` | 1819 |
| `sources/entertainment.lighting_pipe.straight.vwx` | `1d63746da03f923b730844c0e5673bb8bb64a871db2083d271d0929034733163` | `f1187fd0a1dce190f9ff718a260e3661c35cb22517719ffce37a32abfd98f56e` | 1819 |
| `sources/entertainment.seating_section.single.vwx` | `c85ccabaf446edfedebea38ee3c540828f9aec49e98f5281917460118cb30c04` | `1f969d276089bf442d7013183b4d6228044fa5df2d77a82de6146e86a49b892f` | 3757 |
| `sources/entertainment.soft_goods.single.vwx` | `d510daec6dbbf9b55f9689340a3b4aaed6932475c4f348bd3366240026108c41` | `589da5b901629ca92d9519dbe2a68a489b8c1d38af864c2a756e6fb6575265b7` | 1819 |
| `sources/extrude.asym.vwx` | `331a0eec28881304f601a1c16c6fd77c16436c941d3bd91b76c6795d95033bb7` | `4b6101c3df23bb164ec26b07f703044af145c94ac140b0281a85e7df41bea92c` | 1819 |
| `sources/ix.mech.hybrid-2d-3d-class-override.vwx` | `a704414c266966b0a17b5002f7bf81c18b9e395b50f9d0186e15b90e08cded32` | `65896aa14ccefc303d350c9dda55b5d8eae006bc3971db3dc2e21e1399b907ad` | 1819 |
| `sources/ix.mech.nested-reflected-elevated-hidden.vwx` | `21722ea8b3d7c0d83eec67795a039d69a881ab96349f0988a0cce4ff88563fcb` | `1f8bec63751b503dc7245a8f47d8a08061be020d0acf78fa7fc2d58785b455e4` | 1819 |
| `sources/ix.mech.rational-surface-trim-hole-units.vwx` | `b1b4f5525f23f292434732372e823370646a69b5ade89a66ee7f3488278eff14` | `129eb9d03c5c0fc0c18096f69b2ffd11979c95f6e489fe8bc9878e5dd8a333fa` | 1819 |
| `sources/ix.mech.repeated-shared-distinct-metadata.vwx` | `e8d40fcfbefc3563fe0aba1202a11c4161d703a1ba19a661b7d2ba4ce2cbe12b` | `c2cf360b41f53463a73603e296eb85d7206cda0bab464cb6a593a5e5cb03e518` | 1893 |
| `sources/ix.mech.viewport-crop-annotation-visibility.vwx` | `b312d9782c12f3dffd115b027c2b1023503a3cc6ca429078665b692e4ac9a21b` | `5209867f46e6ba400bf04576643a23479c9d7b0b954c7b8ab4eab0f4dd56a856` | 1819 |
| `sources/ix.planar.08a344dc9f96.vwx` | `db465292ac4f32e14caeb786a85b5c0a5b7cdb07fd8b2cdb4a0a831fa92b98ad` | `0a2bcb7d1c6733ab434547b3ee0db3587d5e68d6324627a4849aa3031deef243` | 1819 |
| `sources/ix.planar.18e402f11398.vwx` | `18b7541cee287525feec7cd64ee7d5eeea8b02e14c782ea0792f6592e866a317` | `ca1e7d273d3891ce7ce212dc74addf958c872ca68763b9594c7d1f11fb67dcda` | 1819 |
| `sources/ix.planar.4c9fe9c05a47.vwx` | `6a271b0ea198f30ff8a3dcfd743fd8bcedaa0c85c7f48813b9ac32a5eeb918d7` | `79cdae3a44742eb74af6e33f21d3ffc808a4d65aa9af78ba442c7521fdbdc8c5` | 1819 |
| `sources/ix.planar.7108ea3f547f.vwx` | `07b7c1c08dcc243c029af5c5c737ba2338768acf4f58c494980638aff7d1e072` | `b5cc598839c88cf86021937da50eac82dfffa54db65a49c9a802dae9fd804e58` | 1819 |
| `sources/ix.planar.76a55dfa0e99.vwx` | `6ca4f6b4ca031b4f82ed50be75531ac71b18ef3bfce27d7a92502fb4feaa6848` | `7f40595084fb796f9ba9d7e4cf802c6ea885be97d5ceef06dd390c28719611d0` | 1819 |
| `sources/ix.planar.939badf6bd41.vwx` | `7195d3b366258ec7ac6853835cce8fdb24f9b17ccb9f92d4e576476f4a3f8288` | `b695bfa380e53797734d435db101d0f7534b78b8b77caab747acd659ce9b03ba` | 1819 |
| `sources/ix.planar.acdd57e27bec.vwx` | `fd1ba492d9e57190e764ebb9683ec767ab7125df657d6676a39d5c89cfdeb596` | `d78b5c519f86a39e143b4bb33f3031c95a3817f679028186a9827bf23512eecc` | 1819 |
| `sources/ix.planar.b592862becd2.vwx` | `073e6578d96249b860b05ad043b56d384fae74c0ff6371591699174d212ac9a7` | `dc89583fa47e0eaed0c668ff31df2ef82d000430184f83947a8d193c88a79806` | 1819 |
| `sources/ix.planar.b88144920570.vwx` | `fad0dac07a3ce8183d66fc8861ab85cf30a89ab8b8c791f6712caf89494c9fc4` | `e9989e0cda8ff1d8b3142bf18ad214ebbdc133319c58157dc69e79a61ea10761` | 1819 |
| `sources/ix.planar.c16429abac1c.vwx` | `d1931931cdfb09d9f2bda0c7e6a988b93e79c318dfc2a029cd217ec1cd6aa294` | `6250f51e2e6bb27430517b1aa0ddd39c134f890fe1286354448a85651ba3b92c` | 1819 |
| `sources/ix.planar.d064e8d18eb2.vwx` | `7a8427930af04044e1095a610e6473adb797e68554b7ca9a0ff7b2ead872d443` | `4898726f44937c6cb59428dfb24c1c0a380b4905ccd7fba1d7609858c7284a48` | 1819 |
| `sources/ix.spatial.156868e1946a.vwx` | `00709e832fe4c1c06327200a3e33cb999b8fa8dbaf2d7e796ca80b001eb893d1` | `8a00ba6bcdf4359279f8984380cb8f0592615f9324bebf49b194516d0c4a63c8` | 1819 |
| `sources/ix.spatial.162f3d3ad09e.vwx` | `d85562a814b5c184d0d7698ddecd9651692b4cd448d52d4349c937c100286283` | `18ceb25e7b52095425666087a02b6d5d4f0e6d011e517ad97445820e6b59bb81` | 1819 |
| `sources/ix.spatial.1a3ba3f36c82.vwx` | `0ee0d598615847c91dbcf3141c408161f788ab10d3cdfef80da2efc49feaec9d` | `d5c227cc83812dc6a6f902827be92dfe4a4377e4f917cf6d772fe71eb3ce1059` | 1819 |
| `sources/ix.spatial.479efd6c5e84.vwx` | `3beeca4d170daa3975981df1ed50019473c344277f6e2f4b0d718b3eb3c05a81` | `1b8f022268e98729772e867f231914a7db82500a17a6a1f7a8bd8dad1f24b5f9` | 1819 |
| `sources/ix.spatial.6a273393b8fa.vwx` | `ce689eb7b2fce4a16e0c13574578dbb457b2b3ca4a809c8278ce0b0ea55dd6b3` | `6047382881217bac815e79b3bb819870b6f616a989c2e422d4108c566f71aee0` | 1819 |
| `sources/ix.spatial.6f0844765639.vwx` | `ed1931beeee2a8bc34d7d8433778783b7452e7e932aaaa77559fdb27e5c7560e` | `7e6584c3c51c5c7562e5be0f4e188893bc7981e9b96dce856b95aea776b566a0` | 1819 |
| `sources/ix.spatial.7f9b5bd253be.vwx` | `9672cd86ea6cb9f5fad607aa2be0ad391570d98984fb90515d4bd949bf25e7f6` | `e318318d04dcfae469bf17869db671f4f98da24a564304043f024295564c2be3` | 1819 |
| `sources/ix.spatial.9f0fd0f5c94a.vwx` | `241ea162b036e3c837851faccfeddd0162280797f4e4acad3495fef4ba63a1b7` | `a6a9620c6f881e33cc14a2f5e87222121925992647beb7b2bd076d1494e3d7c7` | 1819 |
| `sources/ix.spatial.ac39b9ac7ebb.vwx` | `382e71e291638ca9a440bf0d3082e3a56c067aaaaaf6a76933932cf395bcf3db` | `2cc793066f287b274a6afe41fa9e799286a4c39ee34b1b91317013b6361d4931` | 1819 |
| `sources/ix.spatial.d26473bbb730.vwx` | `e28c99f0c99fa724a1657bba180a781f93496b28872ffb4f90ba7ad89e484a57` | `ef1942f7026d400579acad88ba84e8bec6c66c762052801a4f644faf98735abc` | 1819 |
| `sources/landscape.hardscape.single.vwx` | `2321db95bf8a9c197bc6e7456f84a9896fddfa602443edebf93b146543d04679` | `d68b6ff97d5ed07c3a0338b1449a337031c97279a30d8b171831764c9c96f9b9` | 8213 |
| `sources/landscape.plant.plugin.vwx` | `5390e21a72f7198b6cfc7c1f132554c7450ba4784ca15cbde83ac8b0c9d54a5b` | `287e8c9599ad2f3fee88adcaf212fe85b34f99b0a08d25a776d7a2c73b9ade49` | 1819 |
| `sources/landscape.plant.single.vwx` | `41e51adcf8c62132fb414546398205957ab625243df1ebade4e45b34db8d2e4f` | `361a42b7594a82a931bf3ea5e2d6ede142aee3ce0b1b6654bcbf999ca5458057` | 1819 |
| `sources/nurbs.curve.closed_rational.vwx` | `701c7d6752a401e8244b89b343f215bd6065ce5e52a997b4c26256d9f69ec1c4` | `e59f9296a042f7b2db86667b53d0cd339cf543f887285ee372f1181e30e5b529` | 1819 |
| `sources/nurbs.curve.cubic.vwx` | `e9c142ff597162a63865df59bbb1f403f6db3cbfe62ee0010cdbf38c66aa93d7` | `8b2b6bd25042bae81faafcd1de6ee686b363074779bba2230ece0f9962f60473` | 1819 |
| `sources/nurbs.from_conversion.extrude.vwx` | `814dde916f8d912a0781c1268933c669fa2bafce40c4fd77b7e5d9f6ac613891` | `3c4d95873288b3e5c7896d4fcb4cbca92ac6bd72b916078456c08b74683b590b` | 1819 |
| `sources/nurbs.loft.closed.vwx` | `bc9548cd09d8a81c1bbd8e153ccdafa76a1d0b79144cda4a2f739a0df33504c1` | `e562337be24651cb2ee97f2be2a8b4a4ea49893d097c80c7399c330f9fa48b8c` | 1819 |
| `sources/nurbs.surface.rational.vwx` | `4894dc5691d95e35c899feabeba69653ad42d53da146708ecf55702f68ce1179` | `a61a348bd1808bf9ed21ff7bfb57a350c1895f7826e5960ef14cb984465cc585` | 1819 |
| `sources/nurbs.surface.revolved.vwx` | `c36e9ea1149ddb9a07e87a751d5ae8756e3153acab6b30a70772fc2947ebc19b` | `d4556cf56d1a829d511ed181d27085d7a321db7360759b1e6a87df1f50609513` | 1819 |
| `sources/option.class.fill_texture.vwx` | `51c450a0ca89166bb9a9b88b0518419b84a04be1c940db400a296c682d727e28` | `87332200ad19967a340f52c292bc1b7eba4341788c47b2f34fb3963de7e89de6` | 1819 |
| `sources/option.drop_shadow.vwx` | `0027bbb797e4f17e7a5fe1a17c3fab72832b76264ab1327ab7445713703c2a27` | `09e7f715af0844d5e08e35ec9bb8645e292e0c90e3520c6469903ca0d5ffa388` | 1819 |
| `sources/option.fill.gradient_applied.vwx` | `47308708ebf48a9bb8ef8e31e47810df4ad5e6bf4ba8b9ddf8676110ea5421cd` | `6f531d4a9257afce819971c6b2f0a81205a16f9e76566b22c7f63f6525acd06d` | 1819 |
| `sources/option.fill.image_applied.vwx` | `bbcd839185120c37df4304f6dfb8f3ba2ad8a14ea4ba6c66cd3356f3c8f1373f` | `fc63d9de1c8fed69dc94be0754f03055552c831a27e8e5f2d33f41d47233701b` | 1819 |
| `sources/option.fill.texture_on_extrude.vwx` | `c96f22f32d6a014be5fb5a6bbcc31fdf3b334265ed61ab2a0b4c9b98b87f6ee4` | `262e54d65b6ecd28e1bfe5a358dd0755b549fdafe4f9ccb020a0204ae47000e0` | 1819 |
| `sources/option.fill.tile_applied.vwx` | `d6362e934a0f2c13ffd89d4c86563178d9e8e26eac071b23622f182e3f28dfea` | `9031855318e5a8fd877dcb0ce1b8ec82a8e491402fce6cdb30507f86fc301053` | 1819 |
| `sources/option.hatch.class_fill.vwx` | `bc3405e162db35f193d2cd5b5508e575f543b494777d049c19e3b4e11d9846c9` | `9d173e1ad6d6519e13324e41b661689b7cba7ecf05453d88e4ae219e804f1eac` | 1819 |
| `sources/option.linetype.complex.vwx` | `c271f7764b0085028f243a56f8d2028b386c818a2ae9f5ee5adb947c1ee07a8e` | `0c2ffdcba7294fd28e986d82e8858c295f80ab7f78870fccaaa75c9947234a42` | 1819 |
| `sources/option.markers.vwx` | `088c94664f092b6858202ffdedb070a46aa6a1bb17d6b720bce1cafb2f832f8f` | `de4137b8bd1135b62f611aef5792e99a5971d54471ff935fe4c0ea66a085064f` | 1819 |
| `sources/option.opacity.vwx` | `6b64c84402bd8fed9b426e0ca573cd2acb58b8499bc3f327fad1aa7ffe7411bb` | `504416e43544dce1491782c5ba41db717a50526ff8263f826b1fa03ad592dff0` | 1819 |
| `sources/option.pen_fill_colour.vwx` | `0222e7d56070d15030d0aa2c80be9b2d4481ee4b1d88e03d41ad14a3086bad19` | `56cb020073a94738d4782cd940741654dca79886cbb09945b949dc9e34144a9d` | 1819 |
| `sources/planar.arc.asym.vwx` | `8ff4cfd2a57df768cadab0ac07b60dbcc30dcfce889d05f1e7be963637337816` | `e5a4ff20362e070b0fb1f3c8d3b00917d96d9afd32a415e4770ba4c1ec2a9e2c` | 1819 |
| `sources/planar.arc.true.vwx` | `6558a007f7c162bdb75aea388b0e8cb16957696907532f87ee9381edb2dae9ca` | `e0d09f046263e2a55c1f0686749e6b001511b0a146d3b1ab60be4f255e0a0a80` | 1819 |
| `sources/planar.circle.asym.vwx` | `6a4e718e5942e9ae877d121975ca59921f34359dd647aff8c679419ad2352e9f` | `3cbc7443271c255a21c330df7ea965841bd0d754764991287234176c4798aabf` | 1819 |
| `sources/planar.line.asym.vwx` | `ae2ac0986ef9ab184a306e3f876e71404596738df0006a1694d73b9f49144d9c` | `2f5595933edff2a4e1baf669bcfedcea8110f80d7bfb23e709038637be45166b` | 1819 |
| `sources/planar.locus.asym.vwx` | `9546ed3e6282d2957178c729ae1f0d192765e2dafb2728784769c8df53bc3466` | `c3679261efadf4e0db0099dc4ccf1300cae781d3443644ce73c2c4e0636dcf31` | 1819 |
| `sources/planar.oval.asym.vwx` | `aa05dad2fe21a8a86bdee19f1923c1d3a073ab0bcf11f01a47431640845f2a23` | `aa533ceac2de1053f6ec91d88c04145bc6c71337b814ae4860354807868c302a` | 1819 |
| `sources/planar.polygon.asym.vwx` | `2a7812d50cbc7da49e12226644637720d950603c1deb2de085e24ceeb851279c` | `11947d65ae37ba8014d593c63a4b1a1b758aaff0e5bf4edb98195ebf33bcc671` | 1819 |
| `sources/planar.polygon.from_polyline.vwx` | `bf6f1ad9d9ea353be5262e3f0d99d1c9b53541cb99f37f1f5c740d7400a17484` | `a8aaf4f0e06176db84d734239211ec5dcf628e624d14698c2be9c577fbb87b9e` | 1819 |
| `sources/planar.polyline.asym.vwx` | `7fefd861451e483c35af9bf0f6df5d349c29db691e9fb4e7e8835bc5139d4fb0` | `d67c822afe7b73fce704a2d3b8cf2bf7fe2d341b40076069517f25a1ca07ff11` | 1819 |
| `sources/planar.rect.asym.vwx` | `4189b397f7647c16a06c30547e27b94ef462f64f71e10ff2107869d05d206865` | `a027635f578194eb47478d6bf11574d1fabda43973dfd2e478a44c144f26892b` | 1819 |
| `sources/planar.rrect.asym.vwx` | `f4978ba5d7af29b6ccbf37bf5ad2dbb33994cf4123adeb3f90c55f3449bbe8f2` | `c29ff7f4d9c99ddf2717a9e8c666574ff85efa5d5e2a91d124e8d2e1e170702d` | 1819 |
| `sources/plugin.combined.01.vwx` | `fd0c157b6f2dcda6e92b5ca7bb14272d6c45956258f1dd115c558c147f5243ac` | `3cc719262279e30d052838c5cba9575d1d42d0cbb6ec3bfae31fef3161be81f7` | 5328 |
| `sources/plugin.combined.02.vwx` | `2d5da81b4363fff7bc46221f7caeff964096d9525481dcc8e316ca022b0acb4c` | `bf5cb04dcdbf3028474c8427b1567071abfd496ab3b8a8de33e76c1316b0eb1c` | 3985 |
| `sources/plugin.combined.03.vwx` | `a6dc7770a97325eb65d4e8c8080a4002abeb5d0c67dd1111a38c54df714c39b7` | `e713aa2b0056fcd2fb7b36922e3fa78fd65c9a7b9922507b03f2d9f60f5370a7` | 3982 |
| `sources/plugin.combined.04.vwx` | `e733c0b8acd3fd967e70ca55cb571f8159b67c1d42477b247f6a2f5f3c3a97d6` | `c79f290438a0a83cc4812c56afce32d24a1cade1e8d90b591803571749ec0977` | 5116 |
| `sources/plugin.combined.05a.vwx` | `1503b81a8dcb964d1184a0c4e234de890a56cb321a837d9a3dd8e8abdef56e36` | `69dd62bab8616ea6dd1798c2f2389d92c89b13118ba76bb1b77cc798f8abe927` | 2511 |
| `sources/plugin.combined.05ba.vwx` | `1658ad8fc4b70a11d2764583b88a25bf7383d980fe9e1b2029f46b631747424a` | `29f38616dba54365b59e76b9de3ea6e5dd202383799fbb47a261b662cf533f21` | 4756 |
| `sources/plugin.combined.06.vwx` | `c2f87d27432a8ac450aeaec59d85c7b2b8294eefd63d7e91c89ae44705530954` | `4a2206af30dde71f3593e509fbcccc26e3abc208c0ffe93224fe269b8b4ca378` | 6721 |
| `sources/plugin.combined.07.vwx` | `546f70302d58ad5cf42e35a561b949d2085de78c23d59fded5e51a436cb36e36` | `03ee29029fb281d30f7ed7c85737077e74ce3fbd59365af58ab012407585ef34` | 11539 |
| `sources/plugin.combined.08.vwx` | `65f2b2cb7ce42f4e01854aa04badef0dda69d17a2ef36d9ae2c2d6028f56b811` | `2de163e476305f5e9b44e8a83f0c1739f3391b982bf5ce64b55f0362bd6084b5` | 9336 |
| `sources/plugin.combined.09.vwx` | `cc32a5c588da4a68196b39d636839271f61f68c86383d95af290ae2f1e3b0a46` | `f5966360efa3b95e37021af4000fa0b188bd4ffb65af7d1a08212cd839c28c76` | 15670 |
| `sources/plugin.combined.10.vwx` | `87b0a58f99d3991e0411a65046dd1d086c471694a61af166c7c4420f6e1d5b18` | `d36e5781541b60f31348848dc8936038e6b5b9cf2b86d2cc12689453033d202b` | 13039 |
| `sources/plugin.combined.11.vwx` | `9888d59637555d6d2b722fbb53453eb6d236d6a45f11d76238654ac874a2d130` | `ec76dd5bdda24850f3efdb18b1aa8a7d41434b3884b1a161b1862d06fea4b858` | 12502 |
| `sources/plugin.combined.12.vwx` | `fb330f68035b3fb2df5282e0e85f5db9e13495a1d089e9710b7231b9b3246df0` | `cf01f35fdba6d598c2c85ea4579e67ca9e8ab4e8d6f493ded2afe35e00a64d18` | 12223 |
| `sources/plugin.combined.13.vwx` | `15af1a089c76fa9d23c5d5563de71e96536c5785ce8f9b9758640e39ccbfbba0` | `03112b3a3c517474def6cc1567f6407f745e1fa46139d23c36ed94c8d14932a7` | 14749 |
| `sources/plugin.combined.14.vwx` | `327920c259013e231502405e07d05919a9a9d3e49ebbb03429caffa32fb4c8a1` | `13233abc25a7fd0b59bf4b2db792e9f20d9a9fcce80834fcdc1131d5c339b38f` | 12143 |
| `sources/plugin.hidden_class.vwx` | `6a3a98f290f1b48c1b0f619bb6f559a3cec7c5fd0ea61dda3563f437f8c8ef39` | `270fd704a10d62e39220b4e63538973ce8360aa4d4c165f56d364889d32e41dc` | 35715 |
| `sources/resource.class.attributes.vwx` | `cc9bdfb6880f0b77371858c6c2a40f1aacd067b0481ed609591306d281a28690` | `256b0d333634b8fdf0a6b10f712f7dd4d2f3387952fa7728baeb09b2a80ceeac` | 1819 |
| `sources/resource.class.visibility.vwx` | `5842f6e2e096501c651a2a88991249289e95ff241e327c740ef771e55dee6ed9` | `9aff92dbc0b293c235755d63a116b7ddecd2c96e1a7e349aec0fe8fd38eceaf2` | 1819 |
| `sources/resource.folder.symbol.vwx` | `bf117d7485c959ac9e02fca58560185aeb304a524ff0ae20a255a364d6b0fab7` | `00ed12b5f0a8fceaa368c4f20b990db22a6ad042776bd9250820e43352b9ce9e` | 1819 |
| `sources/resource.gradient.three_stop.vwx` | `d8daf894fbdc3e7e92786c46cab877d089c169fa063eeed96da1a39c7aad5495` | `0e9b6c006be604334291b8c84c9be16ba24e0a90e107cc6b2078efbcc19c2944` | 1819 |
| `sources/resource.hatch.placed.vwx` | `c4aac0e37916fc8a1811572640095802071853efc296596bbac3b308468267ea` | `c01e66f45352e0adc2bda37c96087ba6e22674de8d703d1bbda1971c37c765f4` | 1819 |
| `sources/resource.hatch.two_layer.vwx` | `8237b97a325b2853ddbae4038db3acd2cbc0fd98babead703bae26fad7f80a30` | `7ed1c2cdf4ad330bdec489864b17c91c00974f5fbc368717aa572cbe6099ebad` | 1819 |
| `sources/resource.linetype.dashed.vwx` | `c185b91742e18e88e4271e39eddef0d525a1e30776ddacfb3fb520993c840739` | `323007e0f6ef9aee16de3a78769431e2098fe55f7c8c864df6eed4d8f36d7e2c` | 1819 |
| `sources/resource.material.simple.vwx` | `3753f8310c08858cd8448380997e920b2452c2317c8b41d41feb67e120df67d0` | `dc4b8652394508537de86a5f6af1c91f89f3f5c8d5800972744cc97f51ff433a` | 1819 |
| `sources/resource.record.attached.vwx` | `6e4c3cb3fe1d4d8e07ecb7ddff880c8b1d24d360833a75d4e858cb243c9eea89` | `6616d6cf305e8dc2d6c56f89578a62542df91e46d98b51aeab190e67450f6902` | 1961 |
| `sources/resource.slab_style.named.vwx` | `31a29c33d3f4a4426d78f574b52cb17ecc2bc701fedecd5ac4d4113822473629` | `f8473fed36eb378f1147af86780185a6a747e5707a2a9428bebcc4a5b550f7fd` | 1819 |
| `sources/resource.text_style.applied.vwx` | `f34653dfff52c2d3bd679a94d0bea516cd49aebfe8c17ded8534e2c4257f3189` | `4cc266487bef770b1833954dd2a02ffa3c9246a543e3c68bff8843587297b033` | 1819 |
| `sources/resource.wall_style.named.vwx` | `ce597fc501f152933d421da2f6248f366c7b0c17d517bcc523a3886cde3378b6` | `2338dcb1db55c7bbad8815b19e07e2d17dd0adf41d8308eb581c78c246c5706c` | 1819 |
| `sources/solid.cone.asym.vwx` | `1291e4baa6c6e0e0cd0cef8d6c60e4f613ef5818fda1ac31d8e8c16b7e2efa42` | `9115455b09e0b25af61adadc690c027aa3d436c5550e384b72b2843b30a8fffb` | 1819 |
| `sources/solid.csg.add.vwx` | `7406a73aa3e723a346d8980594a64270094390705310155f43150aaa38cd2e32` | `81f01a0ee256cada76ad3e9e60c147ec7503ce085af291c60854b8a183898126` | 1819 |
| `sources/solid.csg.intersect.vwx` | `6281bcad327a721d383081792f2afc638bc88f680f039ec6517e10837e55a400` | `899c6b1d87a8d0cf7093c4f0b1820a2e435dcdffae58578652c9e1e5587515dc` | 1819 |
| `sources/solid.csg.subtract.vwx` | `2b9bc47b5815978b6c7d250e8705a54675d7de1e002de9c012707fd26db74c81` | `104a85bfc30960e28281f876b8b4a145d2b0de6e91a7078af3215bcfb5fa1dbe` | 1819 |
| `sources/solid.cylinder.subtract_sphere.vwx` | `faeb3280e65adcc769a92a813e90cdbb5a625cf668d92a259d8de6e744821102` | `1d10ee04df1deccd52abfc7598317c40e2908acec3d57ace99879657666dbe39` | 1819 |
| `sources/solid.extrude.circle.vwx` | `cc7a7fb2ba1fcb5c49d431442bc451779f840927871a1fde482686b327637cad` | `2d30529693d3cdd8774a32cb0406faf1a164de5ff3e8872ac010e6dddb017c90` | 1819 |
| `sources/solid.generic.from_csg.vwx` | `cf80b9ab4cd0bc1e89567e88f2cb015b49e3d5432305cc5814bcb12e2169fca0` | `294c863f23e6f4915be09618321299ba82473abf8ca163de77c42e1135cc9135` | 1819 |
| `sources/solid.hemisphere.tilted.vwx` | `f34330beddb1d22703d77e3cbc862aeb7b0cdfc17c0041f06cd9ed4596ae094a` | `b29bf76b287daa4575a65d05200393f3fcff3a4a287d7da7d4437a6a9fed0853` | 1819 |
| `sources/solid.shell.dome.vwx` | `995cd781db6492bb38a52d0d2c93c0664e47cfcb1f687552d957631d06badfac` | `fb3f2cf04ffb4a01aeddb46f92125f7d0be9edae74f21fbbb11f7a30664b161a` | 1819 |
| `sources/solid.shell.surface.vwx` | `680f740d676b6cd9e5a180cdfb77eb6b2e0dce0f6e2fdcb0926720faefe6648e` | `a106d9cbf0e9d425f3c8b064fdb299fd6ddba00fb046087da1d564c48cdbd8fa` | 1819 |
| `sources/solid.sphere.offset.vwx` | `e3d13f71a68bc161166b3b9dd5aa55f565928fde9b976bf1f5717c46f01e1d65` | `85007d59017a4253fec0091adc1ada292886e051e408c5837caecceaa9d331b9` | 1819 |
| `sources/solid.sphere.union_offset.vwx` | `5330271625df4dda1380e6f7d126a42e669b954fd731bb8c9e4272df5b223990` | `d3c3ea2fdc5ba112299a4f5288e0f0d8c1de4a4ead2a5096a022912721f56535` | 1819 |
| `sources/solid.sweep.circle.vwx` | `98c1fdd0fa15b2b7402f85dac5d0e9cde6e16d6c7fbec2e9bf00cdd4759f03ca` | `d97ca15431dd231d748f0f25d41a8f082b75b5cd0da29f950de4b8d5495e1c79` | 1819 |
| `sources/solid.tapered_extrude.circle.vwx` | `295c7e72dd4bbd084b3ad9e9eabc64a2fe543b7961547459f34cdc8e99020673` | `0f77e1c8603d5744a9573e9cf5c8cece13a1d21286fa7b9c9ce8a2a9651fd3ed` | 1819 |
| `sources/spatial.extrude_along_path.single.vwx` | `469831925b0f4923d8868544fe84aa25effa6799e22d999d2b7a839641e27ab7` | `d0b102483e1d8965ec4a7b8d6877330588924036ad48fb9e3cfc998317148ab9` | 1819 |
| `sources/spatial.floor.legacy.vwx` | `a364e43d5939e680a2847f6563207f942bd4d975b173ccceb2cc928be1f4d2bf` | `4d71ba83a253a03f52b2d8c4c8dd1da409c6be9589cb9da9f83d495036f99ca5` | 1819 |
| `sources/spatial.light.point.vwx` | `47445316893e8e36d64f81dfbbb1dbbd48613e46d2c8894e2e6c00b18e57f730` | `f0ad241b8faf2a13abcf4f92d6c40102ec357af0be10cddf0946117a6513e6f0` | 1819 |
| `sources/spatial.light.spot.vwx` | `79c863c8018d111a5271e8fa748e2c707e036e0fee2ccbe7859f532f3207c9c2` | `18d394bb9b0f44f2cdb91ab9cda18e64885d47efe0545b3d2e4d12b5c64db148` | 1819 |
| `sources/spatial.locus3d.asym.vwx` | `c4dbb4c3d8cf3c3fdedea78683bc371abd65eb4d4c6a727db1bcaa8fe81b7bc9` | `62e63db30d0aae0f93e70a90bdab158ba475a8cc126a278bc498ad72ac55a30a` | 1819 |
| `sources/spatial.mesh.from_group.vwx` | `d8d1717c1c881135c0f6f9cd759c8e25bb9b6c73d03401ad830feaca8bb7f68d` | `9495fcb7cc6db1af91edb6466f73f078fbb0e5cbfee198070f3c82b358c31371` | 1819 |
| `sources/spatial.mesh.tetra.vwx` | `f2e246e4c78ee636b0d9ed06852a160e8c7838de87fe25e94c19a1e4e12535b7` | `494411f50f5d4e372533523f33510504f7d359c50a9098647a9b052a84ac10e6` | 1819 |
| `sources/spatial.mxtrd.asym.vwx` | `cabaf445fc0a7f38fd0a7f9a039add59544d9a5ea64041971b0f2090acc61714` | `5d2deb3e7bd43dbf1c8337613b5ca094b437e1fcec0daffa381c0abc96538c54` | 1819 |
| `sources/spatial.poly3d.asym.vwx` | `13ea3193b78707e3156c6b4e04e57bdf433b8b636ec3af13ef0909c8905a3533` | `e47a175363b3c15c361074b2f0ae0093314d32b91e94661a94842cce59dd7a67` | 1819 |
| `sources/spatial.sweep.asym.vwx` | `29219240be8ad433c1ff186621f648b3de9d0cb863ec59e52751afccfe0da94c` | `d8178bbdbd5e9c5b0978419f48e83f09c2d8fdb67e38522b1b6164197ea4016d` | 1819 |
| `sources/spatial.sweep.pitch.vwx` | `e397dfa955b0880ecd48f50ea5a1a3a7af858af6820ced87d05f6876e51a5903` | `4073968261422f1db8d6e4b3c67aa54c6a8e66e3e84c46f0ad254c0444843871` | 1819 |
| `sources/spatial.tapered_extrude.single.vwx` | `771b2de28f01b3f93c5f41888adad62d5466eea9bb27be4448502f5d18735f0f` | `993e9573764cd18a94d705972fff268cd3d7150bb2877ae45278ba925b68cb4a` | 1819 |

**Text.** Three text files named a private project document that we used to choose export settings. They now say
"a project DWG" or "a project document".

**Generator text.** After generation, we made the generators' comments and notes neutral: where they named the reader
that asked for a case, they now say "a .vwx reader". Their behaviour is unchanged, apart from one description label
that `driver/build-index.py` writes; `ledger/intent.json` and `ledger/manifest.json` carry the new hashes.

## What we kept on purpose

- **Placeholders.** Before publication, our anonymiser replaced the machine's home and volume paths in text and in
  exports with `/Users/user` and `/Volumes/volxxxx`. These placeholders remain in FBX, Parasolid, IFC and STEP
  exports and in files under `driver/`, `extras/`, `runs/`, `docs/` and `tools/`. They name no real path.
- **Print settings.** 31 `.vwx` files hold a macOS print ticket (paper size and print flags) that Vectorworks saves
  with the document. It describes no machine or person, so we kept it.
- **Default content.** Vectorworks and Autodesk write their own content into every file; see NOTICE.

## What we left out

Rosetta includes the driver (`driver/`, docs/REPRODUCING.md). Our working repository also held:

- the run records of each generation batch;
- the driver's evidence, including screenshots;
- studies that read external documents;
- the tools and logs of the people and programs who built Rosetta;
- superseded versions of some sources;
- early files with no case id;
- process tables of the ledger.

We do not publish these: Rosetta works without them, and some hold private data.
