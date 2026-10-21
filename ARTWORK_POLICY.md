# Artwork policy

Product artwork in Carezaar web and native iOS must not contain people: no human photos, illustrations, cartoon people or faces (eyes, nose, mouth, ears), no faces on objects such as suns or moons, and no dolls or stuffed animals. Android parity does not override this policy.

Allowed artwork includes hands-only images, faceless outline person icons, rooms, objects, homes, logos and plain icons.

The policy applies only to artwork supplied by the app. User-uploaded profile photos remain supported in matches, profiles and chats; do not hide or remove them under this rule.

## People-free replacements (21 October 2026)

The people artwork removed in the "Update app artwork" commits (A1, F1, F2, G1, M1, M2) is replaced with people-free pictures that carry the same meaning, under the original names, so the server's reference lists (a care type's `icon`) pick them up:

- Care types `client_senior`, `client_child`, `client_pregnancy`, `client_adult`: glasses, book, cane and tea; toy blocks and rattle; baby onesie and bottle; wheelchair and home.
- My Matches headers `header_*`: a matching room per care type (senior's living room, playroom, nursery, accessible living room), rotating for caregivers with several care types.
- Welcome photo and `bg_intro`: a caregiver's hands holding an older person's hand. Sign-in side photo: a cup of tea passed hand to hand.
- Caregiver skills illustration, Profile header (desk with planner, stethoscope and tea), and 20 icons for care services, qualities, shifts and Help Center support, all objects or hands only.

Every new image was checked by eye for faces before it was added. The automated artwork test keeps the exact bytes of every removed people image out of the product under any name.

Historical audit screenshots, source history and archived restoration evidence are not approved product artwork. Keep them out of product resources and shipped builds.
