UNIVERSAL GALAXY PROJECT — MASTER RECONSTRUCTION PROMPT

Build a deterministic, browser-previewable, Python-first procedural galaxy simulation called UniversalGalaxy. The system must model a galaxy as an active physical environment rather than only a geometric coordinate system. It must be modular and top-down: Galaxy produces macro sector physics, Nebula produces local nebula content from galaxy data without mutating galaxy state, and Stars solves individual stellar identities statelessly from coordinates and seed.

The architecture must favor analytical reconstruction over persistent storage.

==================================================
CORE FILES TO PRODUCE
==================================================

1. universal_galaxy.py
2. nebula.py
3. stars.py
4. A web-based HTML/JavaScript preview dashboard with download links for source files and a ZIP bundle.

==================================================
ARCHITECTURAL PRINCIPLES
==================================================

- Deterministic generation: same seed + same coordinates must produce same outputs across sessions and machines.
- Use SHA256 stable hashing for procedural IDs/seeds where cross-platform reproducibility matters.
- Top-down data flow:
  UniversalGalaxy -> NebulaContentProducer -> StellarSolver.
- Galaxy owns macro sector physics and observed sector data.
- Nebula never mutates Galaxy and never creates real stars; it only produces nebula objects and star placement slots from an explicit star_budget.
- Stars are solved statelessly. No persistent star list inside stars.py.
- Observed data must be immutable/persistent and separated from procedural/regeneratable data.
- Support lazy loading and spatial hashing for open-world/streaming-friendly rendering.
- Avoid brute-force volumetric simulation. Use lightweight analytic field-source methods that can later feed Houdini/UE5/VDB pipelines.
- Galaxy, Nebula and Stars must remain independently testable.
- Simulation must remain scalable and streamable.
- No hidden global state.
- No runtime coupling between rendering and simulation.

==================================================
COORDINATE SYSTEM CONTRACT
==================================================

- Galaxy center is (0,0,0).
- Units are kiloparsecs unless explicitly stated otherwise.
- Right-handed coordinate system.
- Galactic disk lies on X-Y plane.
- +Z points toward galactic north.
- Sector coordinates are integer-indexed via:
  floor(position / sector_size_kpc)
- All modules must use identical coordinate conventions.
- All public APIs must document coordinate units explicitly.

==================================================
DETERMINISTIC RANDOMNESS CONTRACT
==================================================

- Never use global random state.
- Every procedural operation must derive its RNG seed locally from:
  (master_seed + coordinates + entity type + local context).
- Random streams must be isolated per subsystem.
- Changing nebula generation must not alter stellar identities.
- Changing visualization code must not alter simulation outputs.
- Deterministic outputs must remain stable across Python sessions and machines.
- Never use Python hash() for deterministic simulation logic.

==================================================
ENTITY ID CONTRACT
==================================================

All procedural entities must generate stable deterministic IDs using SHA256:

- galaxy_id
- sector_id
- nebula_id
- star_id
- gravity_well_id

IDs must remain stable across regeneration and independent subsystem updates.

==================================================
SIMULATION / VISUALIZATION SEPARATION
==================================================

- Simulation modules must contain no rendering logic.
- HTML dashboard is a consumer of simulation outputs only.
- Visualization state must never affect procedural results.
- Rendering refresh rate must not alter simulation state.
- Browser animation must remain fully decoupled from deterministic physics.

==================================================
STREAMING + CACHE CONTRACT
==================================================

- Sector outputs must be cache-safe and serializable.
- Regeneration of one sector must not require neighboring sectors.
- Neighbor-aware blending may be sampled analytically but not stored globally.
- All sector queries must remain O(1) or near-O(1).
- Large-scale galaxy traversal must support streaming generation.
- Cache invalidation must never alter deterministic outputs.

==================================================
LEVEL OF DETAIL (LOD)
==================================================

The simulation must support scalable level-of-detail:

- Far-distance sectors use statistical summaries only.
- Mid-range sectors generate ghost nebula and star slots.
- Near sectors solve full stellar identities.
- Expensive calculations only occur at requested detail level.
- LOD transitions must remain deterministic.
- Lower LODs must approximate higher LOD aggregate statistics.

==================================================
PHYSICS PRIORITY ORDER
==================================================

Final environmental values must be resolved in deterministic order:

1. Base galactic structure
2. Dark matter halo
3. Spiral/geometry modifiers
4. Ghost nebula modifiers
5. Stellar feedback
6. Radiation events
7. Dust/extinction
8. Habitability clamping

==================================================
UNIVERSALGALAXY.PY REQUIREMENTS
==================================================

Create UniversalGalaxy as a dataclass supporting galaxy types:

- Spiral
- Elliptical
- Barred
- Irregular

Geometry:

- Spiral arms use logarithmic spiral equation:
  r = a * exp(b * theta)
- Add warp_factor.
- Disk edges warp in z using sinusoidal function increasing with radius.
- If is_rotating=False, disable spiral arm equation and switch to dispersion_dominated_bulge_fog distribution.
- Add angular_momentum in range 0.0–1.0.

Chemical and physical gradients:

- Metallicity decreases exponentially with radius:
  Z = Z0 * exp(-R/Rd)
- Add steril_coefficient default 0.001.
- Sterilization radius:
  R_steril = steril_coefficient * sqrt(black_hole_mass_solar)
- Habitability score must hard-clamp to 0 inside sterilization zone.

Sector system:

- Divide galaxy into a 3D grid using sector_size_kpc.
- get_sector_parameters(x,y,z) returns a dictionary containing at least:
  gas_density,
  metallicity,
  metallicity_Z,
  radiation_level,
  star_count_prediction,
  habitability_score,
  sector info,
  geometry info,
  stellar_input / stellar_parameters_input.

Data integration:

- Allow hard-coded Gaia/NASA sector data injection.
- Allow observed Gaia star injection via add_gaia_star.
- Observed stars must include:
  observed=True
  is_procedural=False
- If real data exists, use it; otherwise procedural fallback.

Ghost Nebula and clusters:

- Add GalaxySector with ghost_nebula_map containing 3–5 centers of gravity per sector.
- Each ghost nebula has:
  nebula_id,
  center_kpc,
  sigma_kpc,
  weight,
  age_gyr,
  metallicity_offset,
  gravity_well_id,
  nebula_type.
- nebula_type values include:
  EMISSION,
  DARK,
  SUPERNOVA_REMNANT.
- SUPERNOVA_REMNANT boosts local metallicity by up to 25% and increases radiation.
- Procedural stars are placed around ghost nebula centers by Gaussian cluster logic.
- Stars from same ghost nebula share age and metallicity_offset.

Stellar population inside UniversalGalaxy:

- Include StellarClass enum:
  O, B, A, F, G, K, M.
- Use Kroupa-like IMF distribution:
  75% M,
  12% K,
  8% G,
  remaining F/A/B/O with O rarest.
- ProceduralStar includes:
  mass,
  stellar_class,
  luminosity,
  radius,
  temperature,
  extinction_coefficient,
  apparent_luminosity,
  velocity_vector,
  is_binary,
  gravity_well_id.

Feedback and ISM:

- O/B stars create feedback bubbles / cavities.
- gas_density_at must reduce local gas by at least 90% inside O/B bubble.
- Add deterministic 3D fractal noise to gas density to create patchy ISM.
- Add dust_extinction_at and extinction_coefficient that dims apparent luminosity.

Environment API:

- Add local_turbulence,
  opacity_index,
  magnetic_field,
  environment_tags.
- environment_tags can include:
  DARK_RIFT,
  STAR_FORMING,
  VOID,
  STABLE.
- Spiral-arm inner curves produce interstellar_opacity / dark-rift dust lanes.
- High opacity reduces habitability.
- magnetic_field_strength_microgauss depends on radius and gas density.

Macro cosmology — Great Void layer:

- Add NFW dark matter halo:
  _nfw_halo_density(R) = 1 / (x * (1+x)^2),
  x=max(0.1,R/rs),
  rs=20 kpc.
- Add get_galactic_jet_factor(x,y,z) simulating Fermi bubbles along z axis.
- Add get_entropy_factor(age_gyr): gas depletion over cosmic time.
- Add get_refined_physics(x,y,z) returning:
  entropy_index,
  refined_gas_density,
  dark_matter_density,
  is_in_fermi_bubble,
  galactic_jet_factor,
  total_radiation,
  orbital_velocity_kps,
  gas_depletion_ratio,
  is_intergalactic_medium.
- Add IGM outside galaxy radius:
  very low plasma density.
- Separate gas disk and stellar disk scale lengths:
  stellar_disk_scale_length_kpc,
  gas_disk_scale_length_kpc,
  gas_outer_scale_length_kpc.
- star_count_prediction should follow stellar_density_factor,
  not directly gas_density.

Cosmic evolution:

- Galaxy-wide parameters evolve with cosmic time:
  gas depletion,
  metallicity enrichment,
  radiation evolution,
  star formation decline,
  morphology aging.

stellar_input expansion:

stellar_input must include:

- galactic_radius_kpc
- metallicity
- ambient_gas_density
- radiation_level
- habitability_score
- sector_star_count_prediction
- galaxy_type
- is_procedural
- parent_nebula_id
- stellar_mass / mass
- stellar_age / age
- is_binary
- gravity_well_id
- stellar_class
- luminosity
- radius
- temperature
- extinction
- velocity_vector
- gas_density_normalized
- local_turbulence
- opacity_index
- magnetic_field
- environment_tags
- macro_cosmology

==================================================
NEBULA.PY REQUIREMENTS
==================================================

Create nebula.py as a hybrid procedural content producer.

Core structures:

- Vector3 dataclass
- ChemicalProfile dataclass with:
  h_alpha,
  o_iii,
  s_ii,
  metallicity_z,
  ionization_parameter
- NebulaType enum:
  EMISSION,
  DARK,
  SUPERNOVA_REMNANT,
  REFLECTION,
  PLANETARY
- DataSource enum:
  observed,
  procedural,
  hybrid
- NebulaMorphology IntEnum:
  CLOUD=0,
  FILAMENT=1,
  SHELL=2,
  BIPOLAR=3,
  FRACTAL=4,
  RING=5,
  PILLAR=6
- ObservedNebulaRecord dataclass
- NebulaCloud dataclass
- StarDistributionSlot dataclass
- NebulaSectorContent dataclass
- NebulaRegistry global spatial hash map
- NebulaContentProducer class

Determinism:

- Add import hashlib.
- Add stable_seed(text):
  SHA256 first 8 hex digits -> int.
- Do not use Python hash() for deterministic generation.

Top-down readonly architecture:

- NebulaContentProducer can read Galaxy sector data but must never mutate Galaxy.
- effective_gas = galaxy_gas * nebula_multiplier.

Spatial hashing:

- NebulaRegistry maps sector_key -> observed records.
- Observed records loaded from JSON/CSV.
- If registry has sector observed data, inject it;
  otherwise procedural generate.

Observed/procedural star separation:

- Maintain _observed_stars and _procedural_stars separately.
- inject_observed_star only modifies observed storage.
- distribute/regenerate only modifies procedural slots.
- placed_stars property returns observed + procedural.
- Observed stars must never be deleted by procedural regeneration.

Ellipsoidal nebula shape:

- Replace scalar sigma with:
  sigma_x,
  sigma_y,
  sigma_z.
- Preserve backward compatibility with scalar sigma.
- Auto-convert scalar sigma into xyz values.
- Morphology adjusts axis ratios.

Morphology:

- Morphology depends on:
  turbulence,
  age,
  nebula_type,
  radiation,
  opacity/phase.
- Examples:
  SUPERNOVA_REMNANT -> SHELL/RING
  high turbulence -> FILAMENT
  DARK + turbulence -> PILLAR
  dense/collapsing -> FRACTAL/CLOUD
- Morphology affects star slot distribution and field-source metadata.

Future field conversion:

- Do not implement VDB/voxel volumes.
- Add analytic helper methods:
  density_at_local(x,y,z),
  density_at_world(x,y,z),
  field_source_descriptor().
- Must be cache-friendly and streamable.

Star slot system:

- Nebula creates deterministic star slots only.
- Nebula never creates real stars.
- Slots contain:
  position,
  local_density,
  local_metallicity,
  turbulence,
  parent_nebula_id,
  gravity_well_id.
- StellarSolver consumes slots independently.

==================================================
STARS.PY REQUIREMENTS
==================================================

Create stars.py with a stateless StellarSolver and ProceduralStar.

Rules:

- No persistence:
  no star lists stored in StellarSolver.
- solve_star_slot(...) computes everything from scratch every call.
- Same coordinate + seed + t_univ must produce same star.
- Return None if local gas density is below threshold.
- Read macro physics from UniversalGalaxy sector data and local modifications from NebulaContentProducer.
- No mutation of Galaxy or Nebula.

ProceduralStar dataclass fields:

- star_id
- position
- mass
- temperature
- luminosity
- radius
- stellar_class
- is_remnant
- remnant_type
- velocity_vector
- age_gyr
- t_born_gyr
- lifespan_gyr
- metallicity
- metal_offset
- gas_density
- parent_nebula_id

Temporal identity:

- t_born is determined from seed and environment.
- age = t_univ - t_born.
- age is not stored as mutable history.

IMF:

- Use Kroupa-like probability curve:
  75% M,
  12% K,
  8% G,
  3.5% F,
  1% A,
  0.5% B,
  0.1% O.
- Use power-law sampling inside mass ranges.

Physics:

- Luminosity:
  L ∝ M^3.5
- Radius:
  R ∝ M^0.8
- Lifespan:
  10 * M^-2.5 Gyr
- If age > lifespan:
  mass < 8 -> WHITE_DWARF
  8 <= mass < 25 -> NEUTRON_STAR
  mass >= 25 -> BLACK_HOLE.
- Temperature from L/R relation relative to Sun.
- Spectral class from temperature.
- Velocity = orbital velocity from galaxy macro_cosmology + peculiar velocity from seed.
- If galaxy is not rotating, velocity is chaotic dispersion.

==================================================
WEB PREVIEW DASHBOARD REQUIREMENTS
==================================================

Create an HTML/JS browser dashboard.

Must include:

- Animated rotating galaxy canvas.
- Galaxy type selector:
  Spiral,
  Barred,
  Elliptical,
  Irregular.
- is_rotating toggle,
  angular_momentum,
  animation speed.
- Master seed input.
- Instant deterministic regeneration from seed changes.
- Live get_sector_parameters query using x,y,z inputs and pointer drag on canvas.
- Labeled clusters on galaxy view:
  Sagittarius A* core,
  Scutum-Centaurus arm,
  Orion-Cygnus arm,
  Perseus arm,
  Solar neighbourhood,
  Outer disc.
- Radial profile chart with:
  metallicity Z(r),
  gas_density,
  habitability_score,
  radiation_level,
  star_count_prediction.
- Radial profile table for multiple R values.
- 2D habitability heat map.
- Spiral arms X,Y chart + warp z(r, theta=0) chart.
- Ghost Nebula list showing:
  id,
  type,
  morphology,
  center,
  H-alpha/O-III/S-II.
- NASA/Gaia observed stars list showing:
  source id,
  class,
  mass,
  age,
  metallicity.
- Sector JSON live output.

Download section:

- universal_galaxy.py
- nebula.py
- stars.py
- ZIP bundle containing all source files.

==================================================
DEPLOYMENT REQUIREMENTS
==================================================

- Build/copy files to build/.
- Include source downloads and ZIP bundle.
- Deploy to Vercel or static hosting.
- Do not require a backend for dashboard.
- Dashboard must run entirely client-side.

==================================================
QUALITY REQUIREMENTS
==================================================

- Python dataclasses and typing.
- Deterministic procedural generation.
- No placeholders or TODO stubs.
- No C#.
- No hidden mutable global state.
- No brute-force voxel simulation.
- No backend dependency for visualization.
- Architecture must remain modular, streamable and scalable.
- Galaxy, Nebula and Stars must be independently testable.
- Include basic self-test/demo under:
  if __name__ == '__main__'
  for each Python module.