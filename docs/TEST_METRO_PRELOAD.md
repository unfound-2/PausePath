# Testing-area preload — October 20, 2026

Public OpenStreetMap amenities have been imported directly into the shared
production `pausepath.pois` table. No iOS rebuild or Render deployment is
required to read these rows. These are server-side saved amenities, not offline
maps downloaded to a phone.

| Snapshot | Benches | Bathrooms | Fountains | Cafés | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Houston area | 2,416 | 482 | 264 | 764 | 3,926 |
| DC / Maryland / Virginia area | 12,460 | 1,691 | 743 | 1,657 | 16,551 |

Source timestamp: **2026-10-18T20:25:06Z**. Source: Geofabrik public OSM PBF
extracts for Texas, District of Columbia, Maryland, and Virginia. Attribution:
© OpenStreetMap contributors, ODbL 1.0. Counts describe this snapshot, not a
guarantee that every real-world facility is mapped, public, accessible or open.

## Coverage

Houston: latitude 28.8–31.0, longitude -96.6–-94.2 within the Texas extract.
Includes Houston, Katy, Sugar Land, The Woodlands/Conroe, Baytown and Galveston.

DC: latitude 38.1–40.0, longitude -78.5–-75.8 **intersected with the DC,
Maryland and Virginia extracts**. Includes DC, Arlington/Alexandria, Fairfax,
Reston, Loudoun, Montgomery and Prince George's suburbs, Frederick and
Fredericksburg; also includes parts of the Baltimore area. This is a broad
testing envelope, not an official metropolitan boundary. West Virginia,
Pennsylvania and Delaware portions of the envelope are **not certified
preloaded**. Do not advertise complete coverage of those outer fringes.

## Verification and safeguards

- Every snapshot ID was joined against production by source and external ID:
  Houston 3,926/3,926; DC-area 16,551/16,551; **zero missing**.
- Existing community status, confidence, closures and reviewed attributes were
  preserved by reusing the application's OSM normalization and upsert policy.
- Imports ran in 300-row transactions, with a 250 MiB POI-table/index budget
  and a 450 MiB overall database budget.
- After import: database 37,402,291 bytes; POI table/indexes 16,531,456 bytes;
  27,794 total POIs worldwide. Sizes and counts will change with normal use.
- 144 existing discovery tiles within fully covered Houston and central
  DC/MD/VA rectangles were marked fresh at the source timestamp. New metadata
  was not generated for the entire large envelope; the 10,000-tile guardrail
  remains intact. New viewports can still show background refresh activity
  while immediately returning their already-saved amenities.
- Existing seven-day refresh behavior remains enabled. This one-time preload
  does not create a scheduled regional refresh or eliminate free Render cold starts.

## Reproduce

Keep all large downloads and SQL under ignored `.build/metro-preload/`.
The administrative environment needs `osmium==4.1.1`; it is not a production
API dependency.

1. Download the relevant public Geofabrik state PBF extracts. Keep downloads
   bounded; do not download extra states without reviewing the coverage need.
2. Run `backend/scripts/extract_test_metros.py --region REGION --output SNAPSHOT FILE...`.
   It resolves node/way/relation geometry with bounded ID collections and
   deduplicates shared state-boundary objects. Supply all extracts needed for
   the desired coverage; the script does not prove geographic completeness.
3. Run `backend/scripts/prepare_metro_import.py SNAPSHOT OUTPUT_DIRECTORY`.
4. Execute the generated SQL batches sequentially through the authorized
   administrative connection. Batches are idempotent and retain community data.
   Verify all expected IDs before updating discovery freshness.
5. Check the live search endpoint with supported viewports smaller than 0.1°
   per side, paginate all results, and verify no duplicate IDs.

`download_test_metros.py` is an optional resumable Overpass download path.
Live providers timed out during this preload, so the production import used
the PBF extract path instead. Never mark a failed/partial download as complete.

## Live API checks

Checked on October 20 after importing, using small viewports (these counts are
viewport samples, not metro totals): Houston 246 stops, DC 1,923 across four
pages, Katy 25, Galveston 23, Frederick 334, Fredericksburg 57. No duplicated
IDs across pages. Houston, DC, Frederick and Fredericksburg returned all four
categories; the sampled Katy/Galveston views contained no mapped fountains.
Successful requests took 0.45–0.74 seconds per page. One connection timed out
before the Frederick request; retry succeeded. These are observations, not a
latency guarantee.
