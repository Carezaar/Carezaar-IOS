import XCTest
import CoreLocation
import CryptoKit
@testable import Carezaar

final class PreferenceTests: XCTestCase {
    private static let approvedAndroidImages: [String: String] = [
        "bg_intro.webp": "926509b8b68d0fdfe0c22fd4ac1ec69726646ba1c39a7aa6ef0e527b136f9c54",
        "bg_messages.webp": "e7cebc002ede449f8ad42c90540a483dc5ea4f064523eba3d0b05ae16b032096",
        "bg_profile.webp": "af535d5dd6f5fb46f231e26ec39d76f330aee5275d8c813ab8dd5eb68c97a588",
        "care-type-child.png": "fe923375cb3ea656b75d47eaec08914018396eccdfd681bf19a78b2d112b974a",
        "care-type-pregnancy.png": "619b2804d43a3a72da24277b1cf1e12b0683c3c8da2d58ad0cbcf956eb2bb30c",
        "care-type-senior.png": "ec906f73c509aa2b1133424e6366acebb9ff9bf4d38dcf54c1fc6d01cc65a278",
        "client_adult.webp": "31df4e2fd4a95b477f197052e9c104e20227c2fe6fc316970b98c287729e8a14",
        "client_child.webp": "0003ff47d50f969de5f9c65fa92624d5a165461c1e62482bbb42f857a0a01e23",
        "client_pregnancy.webp": "eac2aaae8a6bd47cd67f0c25e0c99be2a5c391ee944f366c7a8c6aab63a9c623",
        "client_senior.webp": "82b442cb341bd923e70eadf50e9461fe7ab0fb3ad914ae6c7382b12e551dc00a",
        "header_adult.webp": "a4974815e0964777961284016f67871d9f8c4b261999a3e06d135ca7a158b583",
        "header_child.webp": "c5f9556caea46f2bb007d7416026791d535cc57a786be121489491c5a2868b37",
        "header_messages.webp": "e7cebc002ede449f8ad42c90540a483dc5ea4f064523eba3d0b05ae16b032096",
        "header_pregnancy.webp": "120a8df43ce88b9ef660ae2a1c2c5ab9c07bf73621a016fc8f43a3ea067e434f",
        "header_senior.webp": "62f6436f20558099bff5e1b1b5a116b6d980db81f7e4ef34f9d56afcb7199c14",
        "welcome-hands.jpg": "714e647f538d3fd418d1d4e828bd4d6e8f8a83d31c82f08fe6184ac2e81bca93",
    ]

    /// SHA-256 of every people image removed in 94d0f7c ("Update app artwork"). None of
    /// these bytes may ship again except the approved Android images below.
    private static let removedPeopleArtwork: Set<String> = [
        "0003ff47d50f969de5f9c65fa92624d5a165461c1e62482bbb42f857a0a01e23",
        "018594c9f64b28d4d085840f75bceaa9cff0e20e2b5521ad8071ca70d867345b",
        "02653748f77b0e925639516b72a0f1d444b60fce39a99648354ea9e6723e5364",
        "03e59f6a86e52b8dc825e934787bb403dec445552564bface4c8b3e588e589f7",
        "0584897755d723e21ea7e942c04a0f30b23ef9681b7e85cd59eb9c1f9b3724fd",
        "0896c46024f03246493065852af7fc3d0585db95c5a7017e81141d342cae78d9",
        "0ed49a0281e795ba9a2d11d494d5b74ee4595f55a9e545eaa5e35130002dc267",
        "120a8df43ce88b9ef660ae2a1c2c5ab9c07bf73621a016fc8f43a3ea067e434f",
        "146eeb64a388a2fd4b38139dab5a520c229c68428577741022b7618f83289a90",
        "14cd28f5d402d38d85b2b92930d2bbd5e389abf0f1e30255e4bec02b475c2a67",
        "17cdecd2d6ec55812e31dae9f86d26a0d5f55e6cecf8402a9d7e5b2a66400dbe",
        "183ae65fa31c49ce831342ac3c088ac1dcb7a30af87c98f51dffc91c4a1aeff8",
        "1945ac87323508cd48d3cc8f01f3f35cc61b26bb458f2f14e347644c55316548",
        "1d34e3b4be2ce72c901987f5e3ede9dd6086e1e2f74ee2ad1f75ec6d121db1f5",
        "1e2dfed33f2301c41fa3816c74e86c0597695a25d3d6521508d81cef8ea5ee1b",
        "204eb4b2c758356f31f3b9499e815954e69a918322e62e82a1f4f3413d7beae0",
        "21af8ca1dfdbccb6f7c3fbf9e91a0ae64874025fbf8fcab37fc3912378f3a69a",
        "2621db460267803f22ea4f7401eaf6b231732504cb10ba0fc6ac86018e95ac14",
        "2788ca45fc846117b801921eb1bfffa17aaca4d53fcfe3e5d81b628575ff0204",
        "282f66ff3a8ef6640f4149ee32288a52a9949789c038e6c25106699965d3a3f0",
        "2ed9f39e932fd42b7229fd1dcb4c0c9b5363e3a0d4dd9a2733d557a00cec2e2f",
        "30f6a4af9a074d3966dda22b5c08a93ac1db1547d1a55549b5731b5b21143429",
        "31df4e2fd4a95b477f197052e9c104e20227c2fe6fc316970b98c287729e8a14",
        "339aff5a76b69a16685d0c6bfbadd6e3d8da74d83f1bfff01aaa1c35add0a617",
        "3615e4be9ab72caccbef2841672fc08c0fe53c280dd13d85b2b56e85390efd15",
        "388800a621e67a91f975a2eb217bc8b5c06d3c7a0999749db4d8f5702672ed77",
        "3b2465951e3c60f12e107b0b15d2f8c2a374ed87c94450e35d8ff08422aca1fa",
        "3dc8bc4f67d2356491f41f096b6bcc085eebeb3ca7977a0da3f715bed9bc8fd5",
        "3e5f8ea1c370df1c6dfa506bb0784852187bbe7eadec3e7ed71ec1d03dcae78e",
        "4473580fe5c84fbb36afe269929897605aae5f3c54a9db1a64aab66026e79a7c",
        "4479ec7a01a69a24cb6c039f4fd34ddd587948e25c22f23ab389166d3972ab47",
        "48b800f65314ad90a579dc5f58f7436e68eba6a78888a007ce3e96e7bb438a34",
        "495d813b5c4d27de04acb9e94959d26e0af3dcbc2592aedaa5cf8c68840bd361",
        "4ab821a86607a0575946bd95863f8ecd3b477e9bb86fb830c482c67bf5f311c5",
        "4bee58bd1418a81db7783f541ef12c5c6bc5a7811b9cb076cbc98a32c97037b8",
        "4c81a26db717d310ff7454358276a897673cc2da16867f7190f2c2f1e9b1439b",
        "4cff2268b8074bbaaf4cdf85e867f7906503389410b1cf16ed0211e9f30ddd2c",
        "4d1aa78dcc1b6f56544bc0c8cb84589cc03ddf2d884608f5909c2ea94dfe85ae",
        "4fe663551bf871e48c3658c287e80efbf9a0eee8d623596a89817b72374e90b4",
        "508200d8a2f0a4aa1339066f32cc8abb1a2e7f2d95d10fc5ec3a00b07394f0de",
        "53b95169167f64c85d4879b72ec042206884bb30e105b6d3aa2888461f9a57b8",
        "58880460ebdaaf7dc7de1cbe3cdfc91d9223ae04ff4fd6473a1ac100e93a21d0",
        "5c6e7c4061732b32a8c34cca28df3f7263340f15d40514a14373c2d63993aab9",
        "62f6436f20558099bff5e1b1b5a116b6d980db81f7e4ef34f9d56afcb7199c14",
        "64f5a8aa93922717cd852cb7b6e7ea40ee329e0acc25b81859f955f43266f0ea",
        "6bbd1debd7b89737cb1009b9253e007e2c0fa2caba8f4cde3d48d65b399ec6ad",
        "6e7857d27bccebecbfc7ed3a947255efafe7b1e7213aa9dd4060c97e3284fb35",
        "6f162d7749bbc8d7cfe34a7ff6719f78220563839a7ee51814508ebc4a021698",
        "6f79114c9996fec49aaa537b97aeaea4efb86060b6e3277d34662bf272de85a3",
        "6f88559cc0f1cc2cff464324df52ba6cfc41c8be6dcb9df4dff4cdb8243d25f1",
        "705ddf5dd484cd36c05573d4e13c3d5d0f9b87a8898fcb0c4ef8c966cb2e8a8b",
        "7255e25a8b3e5a030da06dd56a6550f0cae94e7da8266adc81bcb030bac2788a",
        "785a2b2a7588c677f551791417f898ca63d02ce423721ba871b08d9f9009a2c3",
        "7b689dea55f1af05a70361df8b74d322dbbb5924cde2b36df735dfc2f75f0bb8",
        "7b7fb9cce94f0097c5ab4d1cdb78be8f2131a02bb53bc5879e928385e7a8e1ec",
        "7c5b7c70996db543f785a8f5abe685a19bab75785ef4c1b7d23a196fc12df941",
        "7f5e6aa8c3041bf0d64bdfae0da5ad1d123d01fb97bba18ec8d4ace46eba0f40",
        "8015a52bbf25b55eafc6b4261a58c88d80788ff6517d9eaef3800eaadd510cdd",
        "803995cde5833bbb190551d53f2098cd7daad5c6eac87bcf249bbfa141b7c687",
        "806c3d0c51fb25718f29b537e7ee495ec856dfef8f30153a842bb9b6ad54716a",
        "82019eeedb164b0b55af4f4e2bb7dccae0fd5db4771afa84ee5c89a448f1f47d",
        "8222ca75fdcbbe40f8020f9a97b9248c627cc47179d2b6826dab5611b976e62b",
        "82b442cb341bd923e70eadf50e9461fe7ab0fb3ad914ae6c7382b12e551dc00a",
        "852b848ac40dc123c3cbf4b5144d54c1f5b414d9e9e254c94400f57b7ef2384f",
        "880804671674088426ad2bb5b4a76d3d1e7d1079f94437699340944aff265bb4",
        "89de514cd390074c569d01f180325c8d5652529f6cab9da80ad30d3cf32531df",
        "8e8c11e57761987a6b83ec11a0418e1e8c413450372ad893f1ec261e9b8e7390",
        "8ef3007a3acbebde82a09a5a2a0d57c29a7b6eed29ddec310958d9ab55559d0a",
        "8faa8a05ac8aec97206757edfa445348952ccb2f65ab4956ca11cbb7bfc43eca",
        "900306a244f21916f7964772b462b76f115c0f8f434ccd03e3f38952c8eabfce",
        "921f306511b789e5bb0bed37ec1581c18f010909d4083ef4b0c57def78cb5c8a",
        "926509b8b68d0fdfe0c22fd4ac1ec69726646ba1c39a7aa6ef0e527b136f9c54",
        "94b5eccf6829765f5506cb5918975324e6768392e677c2183089c5467effdbe0",
        "9731d87ab9317a99dccaa327e7fb92ecc903df65054d41626c867f2c3b86e71d",
        "97dd1baa6b8662cb7b89292e1bb7d317b1cb18ace719022229f3ed352e853932",
        "98152c09d4f6b0e20b687e55b0c1dc0153b96f894c4785107104ad0f732e4744",
        "998eff6aa2865485497510f7dddce96105b3d6fd5b2984194f4a4324999f80db",
        "99f75eaec93cb415099f869c3eccf6132ac26fdc0b9c6e6d996ecae269395123",
        "9be80035fa693a7b7acc50eae3ca1c3974282150e5346c9478d53626909968d1",
        "9ca022108c1fd4ce4aa67273c1f5518d98987b3fd09d4287e4b49913e06482b2",
        "9fba8f6d37a3ae25b47754beb5478dff9e34474ba259b5e0e9520dde9c392690",
        "a18ef095de03e14b4b8aa2ba2316c7d15d7b6d6c58db60b23ae7f8e1b80b2ca2",
        "a4186323cc73f63fc9b6b3752de3cf64bb6e0477934bde346255191dc68665cb",
        "a4974815e0964777961284016f67871d9f8c4b261999a3e06d135ca7a158b583",
        "a4efb5ce1445e472b9e3e7a52bb62eeba8ead26159041567394d80af7c23840b",
        "a8f4ba9b2939e0849389bb3f5fecdb899c0a19f4f4b061726fa8290917ea8259",
        "aad8ffd062b2c8cb9c8615a9d94a59d7fc5a5b665b95d7ea9bd31445001a0f5a",
        "b08b09e3c7a77da90a96a3d3196540bf08a87dec8e36833094e76a53f15911aa",
        "b3c8df56a8d49717f4632a9404111cc87e38a6036c3ac6907f6b83878cca5bca",
        "b6284521fd4ab6825ec59bb04bd98e4a0a2c96669ec2080d1cd10647aac550d4",
        "b629428426ea59ed1cf2a1caa594bf5341c0501939fc9fc134f73778d0c73bc5",
        "b7268566b83d158fd6ff38a76609dda0eaf346f0f8891a02d1639058b43b19f8",
        "b9a60ac1f610e240f8222a426221f61f2c549e5010465620edd90f12352f2bfc",
        "bba7635660074b8222a05b6fea076ca0085b04c44a896f261228642fa949f6bb",
        "bf6cf4e8b06413a683f1c6768f172131ac5420a0bb50effeb4590e6263f3ea14",
        "c2997509dfb1134d96a81046e0be4b8dc74406983eb2ed631a863d36448cb643",
        "c4a1b30b1916dabe3e7dad9cadfc33464386eb35cacf98af744c69e21afc313d",
        "c5f9556caea46f2bb007d7416026791d535cc57a786be121489491c5a2868b37",
        "c70d8d62069db6f96f342610db68cd82ff860bb74470e1e334206353d6eab913",
        "c7fe97184a19f30b66a7dba2a82926265a3155d52adeb54b1428f92f9438ee24",
        "ca7839227b8a94d397f522ebf894c692a750ac5b95be537a47be71b77bd2fbcd",
        "cc8a896a01dafba1a79a3ce0203ee075178fa9a27ed498d3ac088e9dcc6a73db",
        "cf345ff4987f59b4073d922687764ed3ea4d31bb9219c4ded7ce02f8fc552146",
        "d2e85fdbafb5649071a113019081ec7d7fb1b4ac14154afbb7650adef0c6e295",
        "d9d650e232081953cd841503b40551c73eda0d4857db7c35601f8668632bd3c6",
        "daee5251c34c8e0fb9facf391c452160392cdd81f9aa334c4ecc5f0817771f55",
        "dcb8faa41605a2938a97f8c35d0ac5ce89e87d437f66612a8847c9c87e089abf",
        "ddbc094cb90c1a9cc7538eb302cf17811b0be5a7528a8aea444769b2382a3de5",
        "dea2b17df03d9c184ccdd637d7a0bc9656daafd1ec188a2c0cb6bf088d1cf0da",
        "defeb3faf1b0b2aef4edd8fedab0ea2b89e5b473e48a9e7cacb857e243108f4f",
        "e2463f125083ca2860b04545889e74bae0d5b2a5a44f913a12785d46aa46a4ce",
        "e39fe2301ebe046657bc85373560e8bdb3a616e5ddca2e9666834c45c2b0b2b7",
        "e3a16af9f82cb83af9ea150527847f2ad6d68ef4a77d470d5c965deea9eee0fe",
        "e4c83b97df29d273fb65189f71c5623764ea103b7afc743e93b04dcbbfe5e44f",
        "e7cb6fd0c8a4f4081c243e6df919724c2668cd992b1dd8cf1a86f6b4ee700066",
        "eac2aaae8a6bd47cd67f0c25e0c99be2a5c391ee944f366c7a8c6aab63a9c623",
        "ec274dcaeb79d1d4bbe71efee5bbc9f26376f22a99f3b261f9088c8c1711dedf",
        "efbd6130713178cf4a22150d3abf8b5a007cbf8f971c89274dc8cb425b2576ac",
        "efc11e64286d1932c8821e76487778e9102d48b4d7d4d6676824e2a1b37e3353",
        "f008b2d44ecb2cea4ebe540408872930ff3e30ba18952830393d3e7a5f8b3cee",
        "f0aabfa24ee85da6d2f6620d2ba74889f53cd15161c602841cd008ad4fd9a821",
        "f1a9d64a00a4dc44b9902be2cf14ec0405cef03fa0a2d69ae77b0b4fa1ab25e0",
        "f7eebc643c74c85787981ed3823278db84bd87dc913e60d9714bfd21b79131d0",
        "f8cb3fb7ec5f3d64a15a7b26e8ee76f02741f48e965d8506dd3a0c195f3432b1",
        "fad22aea01f70aba275af116fc0b9c9c0a68dba67751cfc093b3f9bcf2366046",
        "fd645ebe0432f468fccf8dee8cfd5bb9fa25a8b8e36d5fc0814778559b8618ab",
        "fea316664c347836a94a9c51e95171c635afbdc02b30fa4163b047f5e3510aff",
    ]
    /// SHA-256 of the joined path data of the 20 people vectors removed in 94d0f7c.
    private static let removedPeopleVectors: Set<String> = [
        "08eb035134581321d8c88e30abe7b05870d9e136d37b3b545763cfdbb1cf6024",
        "112f967ae3c8448af2d82e9942a3d93fe669a14eaeb9b07b6bad997cd4e49e08",
        "15289d5fa6e0cff2c745858a8057f184cdb23a9467db99eb4a6717312739ee8b",
        "2170cf9ef9825138deb70e606fe87d0693f77e12a68a1731cc2673bcba639afb",
        "373c26499ab879ebb7f9fa8d5a622512caadfeba66c489ace1ee817605e0320d",
        "3fef7fbce42f5643a9ee6a57c36040e8e5449282121837b36f067c72a2dd7893",
        "4b4ee0df3fbcc9f5bae4e00288aaca341d668c78ef3b9e120827e87e39e7d112",
        "52ed841431d7a6cdbf3abc4f117c0205da93e54c281637196a1136855943a16b",
        "5eb5362d6a2b45a925c33ddb9c0ee7af63b1e9ed6e2444388197b0b458e134ac",
        "6a220d5877965ae91ee6dcfee25299eb012b9f101127c86b533d2a7b9047d3a8",
        "82ec7a22aa400cac865be631533f9f3d27d48f1943586a297ee732fd91a6ddae",
        "86f94e332b5447d738083a8dbedf43dcc2ca31b63fc3bc54044be156ebf96938",
        "8f7459e18e1dec5c128ea58d45e360e8f5d5450b864936bf66418a8321930510",
        "9b2f1efc1ac3066a7b2cfc3ffd39c7825fe39708c01ed9a8a67041e5e92c512b",
        "a149bb0e0dbedbbbe26626bb20649475f900dcbb66cc7d637a9fc7a8648e44d8",
        "a36085e459018a096e2ee66466d276d32dea9586cc5e8941463ee889c4001f8c",
        "a9797a1f47cf59015cf7f7fb5ab0f50fcacc74ce7a6539a1734770a77fc1db50",
        "cf2b17506d2a48b7b2df7d0e10013239ac97a043ad886a35261bdd56267f3be5",
        "d7a79c578ef073536b92a69cf82467e510ed8be1ff1c14c71a0a8959ec6a83b1",
        "f8325071a2af1222b629b70de4c93c8ba2834a79fcb45cbd8d7700a5b27bdb16",
    ]

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testApprovedAndroidImagesAndExcludedArtwork() throws {
        let assets = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Assets"))
        let files = try XCTUnwrap(FileManager.default.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey]))
        var checked = 0
        for case let url as URL in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let hash = sha256(try Data(contentsOf: url))
            if let expected = Self.approvedAndroidImages[url.lastPathComponent] {
                XCTAssertEqual(hash, expected, "Android image differs: \(url.lastPathComponent)")
            } else {
                XCTAssertFalse(Self.removedPeopleArtwork.contains(hash), "Removed artwork shipped again: \(url.lastPathComponent)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
    }

    func testProductImageReplacementsExist() {
        // Care types, rotating My Matches headers, welcome background and Profile header.
        for name in ["bg_intro", "bg_profile", "client_pregnancy", "client_senior", "client_adult", "client_child",
                     "header_pregnancy", "header_senior", "header_adult", "header_child", "header_messages"] {
            XCTAssertNotNil(AppImage.load(name), "Product image missing: \(name)")
        }
        // Care services, qualities, shifts and Help Center support, redrawn without people.
        for name in ["ic_caregiver", "ic_client", "ic_condition_assessment", "ic_condition_babysitting_nanny",
                     "ic_condition_companionship", "ic_condition_feeding", "ic_condition_overnight_care",
                     "ic_condition_personal_care", "ic_condition_wound", "ic_shift_afternoon", "ic_shift_evening",
                     "ic_shift_morning", "ic_special_calm", "ic_special_compassionate", "ic_special_culturally_aware",
                     "ic_special_driver", "ic_special_good_communicator", "ic_special_pet_friendly",
                     "ic_special_respectful", "ic_support", "ic_user"] {
            guard let vector = AndroidVectors.shared.vector(name) else { XCTFail("Icon missing: \(name)"); continue }
            XCTAssertFalse(AndroidVectors.shared.paths(name).isEmpty, name)
            XCTAssertEqual(Self.removedPeopleVectors.contains(sha256(Data(vector.paths.map(\.d).joined().utf8))), name != "ic_user",
                           "Android vector differs: \(name)")
        }
        XCTAssertEqual(SourceStore.assetURL("92bf103484e337567f379617f79c6c37ba10484d.jpg")?.lastPathComponent, "welcome-hands.jpg")
        XCTAssertEqual(SourceStore.assetURL("2c0c41de4775bed358fedceb4f03ba6bd2b76913.png")?.lastPathComponent, "care-type-senior.png")
        XCTAssertEqual(SourceStore.assetURL("80e754df1acd580e680f27c317c16f17a8ffb0eb.png")?.lastPathComponent, "care-type-child.png")
        XCTAssertEqual(SourceStore.assetURL("b8a5332565873bf014bb9feaf8faef4b797407fe.png")?.lastPathComponent, "care-type-pregnancy.png")
    }

    func testEqualAndReversedPayUseManagedRangeError() {
        for role in [UserRole.client, .caregiver] {
            XCTAssertEqual(PreferenceValidation.payProblem(minimum: 10, maximum: 10, role: role), "general_salary_min_max")
            XCTAssertEqual(PreferenceValidation.payProblem(minimum: 12, maximum: 10, role: role), "general_salary_min_max")
            XCTAssertNil(PreferenceValidation.payProblem(minimum: 10, maximum: 12, role: role))
        }
    }

    func testExistingRoleSpecificMissingPayRulesRemain() {
        XCTAssertNil(PreferenceValidation.payProblem(minimum: nil, maximum: nil, role: .client))
        XCTAssertEqual(PreferenceValidation.payProblem(minimum: nil, maximum: 12, role: .caregiver), "general_required")
        XCTAssertEqual(PreferenceValidation.payProblem(minimum: 10, maximum: nil, role: .caregiver), "general_required")
    }

    func testClientSkillsProceedWithoutCertificationsAndKeepOtherRequirements() {
        XCTAssertNil(PreferenceValidation.skillsProblem(role: .client, conditions: [1], specials: [1], experiences: [1], roles: [1], certifications: [], languages: [1]))
        for certificates in [[1], [1, 2]] {
            XCTAssertNil(PreferenceValidation.skillsProblem(role: .client, conditions: [1], specials: [1], experiences: [1], roles: [1], certifications: certificates, languages: [1]))
        }
        XCTAssertEqual(PreferenceValidation.skillsProblem(role: .client, conditions: [1], specials: [1], experiences: [], roles: [1], certifications: [], languages: [1]), "signup_form_client_minimum_experience")
        XCTAssertEqual(PreferenceValidation.skillsProblem(role: .caregiver, conditions: [1], specials: [1], experiences: [1], roles: [], certifications: [], languages: [1]), "signup_form_caregiver_role")
    }

    func testRealCachedLocationCanBeUsedWithoutManualSelection() {
        let location = CLLocation(coordinate: .init(latitude: 51.5, longitude: -0.12), altitude: 0, horizontalAccuracy: 20, verticalAccuracy: -1, timestamp: Date())
        XCTAssertEqual(LocationProvider.usableCoordinate(from: location)?.latitude, 51.5)
        XCTAssertFalse(LocationProvider.isStale(location))
    }

    func testInvalidCoordinatesAndFutureFixCannotSeedTheMap() {
        for point in [CLLocationCoordinate2D(latitude: .nan, longitude: 1),
                      CLLocationCoordinate2D(latitude: 91, longitude: 1),
                      CLLocationCoordinate2D(latitude: 1, longitude: 181)] {
            XCTAssertNil(LocationProvider.initialMapCoordinate(point))
        }
        let future = CLLocation(coordinate: .init(latitude: 51.5, longitude: -0.12), altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: Date(timeIntervalSinceNow: 3_600))
        XCTAssertNil(LocationProvider.usableCoordinate(from: future))
    }

    func testMissingLocationDoesNotBecomeAFabricatedMapSelection() {
        XCTAssertNil(LocationProvider.initialMapCoordinate(nil))
        let actual = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        XCTAssertEqual(LocationProvider.initialMapCoordinate(actual)?.longitude, -0.12)
    }

    func testStaleLastKnownLocationRetainsHonestAgeAndInvalidFixIsRejected() {
        let stale = CLLocation(coordinate: .init(latitude: 51.5, longitude: -0.12), altitude: 0, horizontalAccuracy: 100, verticalAccuracy: -1, timestamp: Date(timeIntervalSinceNow: -3_600))
        XCTAssertNotNil(LocationProvider.usableCoordinate(from: stale))
        XCTAssertTrue(LocationProvider.isStale(stale))
        let invalid = CLLocation(coordinate: .init(latitude: 51.5, longitude: -0.12), altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date())
        XCTAssertNil(LocationProvider.usableCoordinate(from: invalid))
        XCTAssertNil(LocationProvider.usableCoordinate(from: nil))
    }
}
