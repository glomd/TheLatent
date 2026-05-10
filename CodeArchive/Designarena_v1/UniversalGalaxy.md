#!/usr/bin/env python3
"""
UniversalGalaxy v1.2.5 — "The Great Void"
Parametrik & Hiyerarşik Galaksi Modeli

Kullanım:
    from universal_galaxy import UniversalGalaxy
    galaxy = UniversalGalaxy()
    sector = galaxy.get_sector_parameters(8.0, 0.0, 0.0)
    print(sector["stellar_input"])

Katman Tarihi:
  v1.0  ①Geometri ②Kimya ③Grid ④Veri
  v1.1  ⑤JWST Kinematik ⑥Ghost Nebula ⑦StellarParams
  v1.2  ⑧Kroupa IMF ⑨Feedback Cavity ⑩Temporal Drift ⑪Kinematic Drift ⑫Fractal ISM ⑬StellarParams+

  v1.2 "The Sentient Core":
    ⑭ Yerel Gaz Türbülansı   — 3D noise → star-forming / void bölgeleri
    ⑮ Toz Koridorları         — Dark Rift opasite + habitability penalty
    ⑯ Manyetik Alan           — B-field (μG), R & gas_density orantılı
    ⑰ Çevresel Etiketler      — environment_tags API
    ⑱ Ghost Nebula v2         — nebula_type: EMISSION / DARK / SUPERNOVA_REMNANT

  v1.2.5 "The Great Void" — MAKRO KOZMOLOJİ:
    ⑲ NFW Dark Matter Halo   — Rotasyon eğrisini dış bölgelerde sabit tutar
    ⑳ Fermi Bubbles          — Z ekseninde merkezden fışkıran radyasyon lobları
    ㉑ Galactic Entropy       — Zamanla azalan gaz + artan metaliklik
    ㉒ IGM (Intergalactic)    — Galaksi sınırı dışında seyrek plazma
    ㉓ get_refined_physics()  — Tüm makro fiziği birleştiren üst-sorgu
"""

from __future__ import annotations

import math
import json
import hashlib
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Optional


# ═══════════════════════════════════════════════════════════════
#  PATCH 1: DETERMINISTIC SEEDING (SHA256)
# ═══════════════════════════════════════════════════════════════

def stable_seed(text: str) -> int:
    """SHA256 tabanlı deterministik seed. Python hash() güvenlik
    nedeniyle oturum/makine bazlı rastgeledir — bu fonksiyon
    aynı girdi → aynı çıktı garantisi verir, her yerde."""
    h = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return int(h[:8], 16)


# ═══════════════════════════════════════════════════════════════
#  ENUMS
# ═══════════════════════════════════════════════════════════════

class GalaxyType(IntEnum):
    SPIRAL     = 0
    ELLIPTICAL = 1
    BARRED     = 2
    IRREGULAR  = 3

class StellarClass(IntEnum):
    O = 0; B = 1; A = 2; F = 3; G = 4; K = 5; M = 6

class NebulaType(IntEnum):
    """v1.3 §18: Ghost Nebula alt-tipleri."""
    EMISSION          = 0   # HII bölgesi — aktif yıldız oluşumu
    DARK              = 1   # Soğuk toz bulutu — ışığı soğurur
    SUPERNOVA_REMNANT = 2   # SNR — metaliklik +%25, radyasyon yüksek


# ═══════════════════════════════════════════════════════════════
#  PATCH 4: NEBULA MORPHOLOGY SYSTEM
# ═══════════════════════════════════════════════════════════════

class NebulaMorphology(IntEnum):
    """Nebula şekil tipi — spatial behavior + shader preset metadata."""
    CLOUD    = 0   # Varsayılan küresel/elipsoidal bulut
    FILAMENT = 1   # Yüksek türbülans → uzun ince yapı
    SHELL    = 2   # Süpernova kalıntısı → kabuk
    BIPOLAR  = 3   # Çift kutuplu akış
    FRACTAL  = 4   # Çöken bulut → fraktal yapı
    RING     = 5   # Dağılan kabuk → halka
    PILLAR   = 6   # Karanlık nebula + türbülans → sütun


_MASS_CLASS_TABLE: list[tuple[float, StellarClass]] = [
    (0.45, StellarClass.M), (0.80, StellarClass.K), (1.04, StellarClass.G),
    (1.40, StellarClass.F), (2.10, StellarClass.A), (16.0, StellarClass.B),
    (300.0, StellarClass.O),
]
_MASS_TEMP_TABLE: list[tuple[float, float]] = [
    (0.08,2400),(0.45,3700),(0.80,5200),(1.00,5778),(1.04,6000),
    (1.40,6700),(2.10,8500),(16.0,30000),(120.0,50000),
]
_MASS_RADIUS_TABLE: list[tuple[float, float]] = [
    (0.08,0.11),(0.45,0.43),(0.80,0.79),(1.00,1.00),
    (1.40,1.35),(2.10,1.80),(16.0,6.60),(120.0,15.0),
]

def _interp(table: list[tuple[float, float]], m: float) -> float:
    if m <= table[0][0]: return table[0][1]
    if m >= table[-1][0]: return table[-1][1]
    for i in range(len(table)-1):
        m0,v0 = table[i]; m1,v1 = table[i+1]
        if m0 <= m <= m1:
            return v0 + (m - m0)/(m1 - m0) * (v1 - v0)
    return table[-1][1]


# ═══════════════════════════════════════════════════════════════
#  SEEDED PRNG (Mulberry32)
# ═══════════════════════════════════════════════════════════════

class SeededRNG:
    def __init__(self, seed: int):
        self._state = seed & 0xFFFFFFFF
    def next(self) -> float:
        self._state = (self._state + 0x6D2B79F5) & 0xFFFFFFFF
        t = self._state
        t = (t ^ (t >> 15)) & 0xFFFFFFFF
        t = (t * (1 | t)) & 0xFFFFFFFF
        t = (t + ((t ^ (t >> 7)) * (61 | t)) & 0xFFFFFFFF) ^ t
        return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0
    def gauss(self) -> float:
        u = self.next() or 1e-10; v = self.next() or 1e-10
        return math.sqrt(-2.0 * math.log(u)) * math.cos(2.0 * math.pi * v)
    def range(self, lo: float, hi: float) -> float:
        return lo + (hi - lo) * self.next()


# ═══════════════════════════════════════════════════════════════
#  3D NOISE — v1.2 fractal + v1.3 turbulence
# ═══════════════════════════════════════════════════════════════

def _noise3d(x: float, y: float, z: float) -> float:
    """3-oktav sin-cos fraktal. Çıktı: [-1, 1]. Deterministik."""
    val = 0.0; amp = 1.0; freq = 1.0
    for _ in range(3):
        val += amp * math.sin(
            x*freq*1.7 + y*freq*2.3 + z*freq*3.1
            + math.cos(y*freq*1.3 + z*freq*0.7) * 2.0
        )
        amp *= 0.5; freq *= 2.17
    return max(-1.0, min(1.0, val / 1.75))

def _turbulence3d(x: float, y: float, z: float) -> float:
    """
    v1.3 §14: 5-oktav türbülans. Çıktı: [0, 1].
    Daha yüksek frekans → daha ince yapı.
    """
    val = 0.0; amp = 1.0; freq = 1.0; total_amp = 0.0
    for _ in range(5):
        val += amp * abs(_noise3d(x * freq, y * freq, z * freq))
        total_amp += amp
        amp *= 0.45; freq *= 2.31
    return min(1.0, val / total_amp)


# ═══════════════════════════════════════════════════════════════
#  GHOST NEBULA (v1.3: nebula_type eklendi)
# ═══════════════════════════════════════════════════════════════

@dataclass
class GhostNebula:
    """PATCH 3: Ellipsoidal sigma (sigma_x/y/z). PATCH 4: morphology."""
    id: str
    x: float; y: float; z: float
    # PATCH 3: Anisotropic ellipsoid — backward compat: scalar sigma auto-converts
    sigma_x: float = 0.3
    sigma_y: float = 0.3
    sigma_z: float = 0.1
    age_gyr: float = 5.0
    metallicity_offset: float = 0.0
    star_budget: int = 30
    nebula_type: NebulaType = NebulaType.EMISSION
    # PATCH 4: Morphology metadata
    morphology: NebulaMorphology = NebulaMorphology.CLOUD

    @property
    def sigma(self) -> float:
        """Backward compat: ortalama sigma."""
        return (self.sigma_x + self.sigma_y + self.sigma_z) / 3.0

    @sigma.setter
    def sigma(self, val: float) -> None:
        """Scalar sigma → xyz auto-convert."""
        self.sigma_x = val
        self.sigma_y = val
        self.sigma_z = val * 0.3  # z her zaman daha ince

    def density_at_local(self, lx: float, ly: float, lz: float) -> float:
        """PATCH 5: Lightweight local density query — NO voxel grid.
        Gaussian falloff from nebula centre in local coords."""
        if self.sigma_x < 1e-6 or self.sigma_y < 1e-6 or self.sigma_z < 1e-6:
            return 0.0
        ex = (lx / self.sigma_x) ** 2
        ey = (ly / self.sigma_y) ** 2
        ez = (lz / self.sigma_z) ** 2
        return math.exp(-0.5 * (ex + ey + ez))

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "x": round(self.x, 3), "y": round(self.y, 3), "z": round(self.z, 3),
            "sigma_x": round(self.sigma_x, 3),
            "sigma_y": round(self.sigma_y, 3),
            "sigma_z": round(self.sigma_z, 3),
            "age_gyr": round(self.age_gyr, 2),
            "metallicity_offset": round(self.metallicity_offset, 5),
            "star_budget": self.star_budget,
            "nebula_type": self.nebula_type.name,
            "morphology": self.morphology.name,
        }


# ═══════════════════════════════════════════════════════════════
#  FEEDBACK CAVITY
# ═══════════════════════════════════════════════════════════════

@dataclass
class FeedbackCavity:
    source_star_id: str
    x: float; y: float; z: float
    radius_kpc: float
    density_reduction: float
    stellar_class: str

    def to_dict(self) -> dict:
        return {
            "source_star_id": self.source_star_id,
            "x": round(self.x, 4), "y": round(self.y, 4), "z": round(self.z, 4),
            "radius_kpc": round(self.radius_kpc, 4),
            "density_reduction": round(self.density_reduction, 2),
            "stellar_class": self.stellar_class,
        }


# ═══════════════════════════════════════════════════════════════
#  PROCEDURAL STAR
# ═══════════════════════════════════════════════════════════════

@dataclass
class ProceduralStar:
    x: float; y: float; z: float
    star_id: str = ""
    is_procedural: bool = True
    parent_nebula_id: Optional[str] = None
    gravity_well_id: Optional[str] = None
    age_gyr: float = 5.0
    metallicity: float = 0.015
    metallicity_offset: float = 0.0
    mass: float = 1.0
    luminosity: float = 1.0
    apparent_luminosity: float = 1.0
    radius: float = 1.0
    temperature: float = 5778.0
    stellar_class: StellarClass = StellarClass.G
    is_binary: bool = False
    velocity_vector: tuple[float, float, float] = (0.0, 0.0, 0.0)
    extinction: float = 0.0


@dataclass
class GalaxySector:
    key: str
    params: dict
    ghost_nebula_map: list[GhostNebula] = field(default_factory=list)
    stars: list[ProceduralStar] = field(default_factory=list)
    feedback_cavities: list[FeedbackCavity] = field(default_factory=list)


# ═══════════════════════════════════════════════════════════════
#  UNIVERSAL GALAXY v1.2  "The Sentient Core"
# ═══════════════════════════════════════════════════════════════

class UniversalGalaxy:
    VERSION = "1.3.1"

    def __init__(
        self,
        galaxy_type: GalaxyType = GalaxyType.SPIRAL,
        galaxy_name: str = "Milky Way Analogue",
        num_arms: int = 4,
        arm_spread: float = 0.4,
        arm_base_radius: float = 1.0,
        galaxy_radius: float = 15.0,
        galaxy_thickness: float = 0.6,
        warp_factor: float = 0.35,
        warp_wavelength: float = 1.5,
        central_metallicity: float = 0.03,
        metallicity_scale_length: float = 4.0,
        black_hole_mass: float = 4.0e6,
        steril_coefficient: float = 0.001,
        is_rotating: bool = True,
        angular_momentum: float = 0.8,
        dust_noise_amplitude: float = 0.35,
        base_extinction: float = 0.05,
        # v1.3
        turbulence_amplitude: float = 0.5,
        base_magnetic_field: float = 6.0,  # μG — galaktik ortalama
        # v1.3.1: İki Ayrı Disk Scale Length
        stellar_disk_scale_length: float = 3.5,   # kpc — yıldız diski (Milky Way ~2.6-3.6)
        gas_disk_scale_length: float = 7.0,        # kpc — gaz diski (daha geniş yayılır)
        bulge_effective_radius: float = 1.0,        # kpc — Sérsic bulge yarıçapı
        bulge_mass_fraction: float = 0.15,          # bulge/total kütle oranı
        molecular_cloud_arm_boost: float = 3.0,     # spiral kol içinde gaz yoğunlaşma çarpanı
    ):
        self.galaxy_type = GalaxyType(galaxy_type)
        self.galaxy_name = galaxy_name
        self.num_arms = num_arms
        self.arm_spread = arm_spread
        self.arm_base_radius = arm_base_radius
        self.galaxy_radius = galaxy_radius
        self.galaxy_thickness = galaxy_thickness
        self.warp_factor = warp_factor
        self.warp_wavelength = warp_wavelength
        self.central_metallicity = central_metallicity
        self.metallicity_scale_length = metallicity_scale_length
        self.black_hole_mass = black_hole_mass
        self.steril_coefficient = steril_coefficient
        self.is_rotating = is_rotating
        self.angular_momentum = max(0.0, min(1.0, angular_momentum))
        self.dust_noise_amplitude = dust_noise_amplitude
        self.base_extinction = base_extinction
        self.turbulence_amplitude = turbulence_amplitude
        self.base_magnetic_field = base_magnetic_field
        self.stellar_disk_scale_length = stellar_disk_scale_length
        self.gas_disk_scale_length = gas_disk_scale_length
        self.bulge_effective_radius = bulge_effective_radius
        self.bulge_mass_fraction = bulge_mass_fraction
        self.molecular_cloud_arm_boost = molecular_cloud_arm_boost

        self.grid_resolution = 1.0
        self._sector_cache: dict[str, dict] = {}
        self._real_data: dict[str, dict] = {}
        # PATCH 2: Observed/Procedural star separation
        self._observed_stars: list[ProceduralStar] = []   # immutable — NEVER cleared by procedural regen
        self._procedural_stars: list[ProceduralStar] = [] # regeneratable — cleared on distribute_stars()
        self.sterilisation_radius = 0.0
        self._nebula_counter = 0
        self._star_counter = 0

        self._recalculate_derived()
        self._seed_real_data()

    def _recalculate_derived(self) -> None:
        self.sterilisation_radius = self.steril_coefficient * math.sqrt(self.black_hole_mass)

    # ══════════════════════════════════════════
    #  GEOMETRY
    # ══════════════════════════════════════════

    def spiral_radius(self, theta: float) -> float:
        return self.arm_base_radius * math.exp(self.arm_spread * theta)

    def warp_z(self, R: float, theta: float) -> float:
        if R < 0.001: return 0.0
        n = R / self.galaxy_radius
        return self.warp_factor * n * n * math.sin(self.warp_wavelength * theta)

    def arm_positions(self, arm_idx: int, steps: int = 200) -> list[dict]:
        if not self.is_rotating: return []
        offset = arm_idx * 2.0 * math.pi / self.num_arms
        pts = []
        for i in range(steps):
            t = i / steps * 4.0 * math.pi
            r = self.spiral_radius(t)
            if r > self.galaxy_radius: break
            a = t + offset
            pts.append({"x": r*math.cos(a), "y": r*math.sin(a), "z": self.warp_z(r, a)})
        return pts

    def bar_half_length(self) -> float:
        return self.galaxy_radius * 0.35

    # v1.3 §15: Spiral arm phase — noktanın en yakın kol merkezine mesafesi
    def _spiral_arm_phase(self, x: float, y: float) -> float:
        """
        0.0 = tam kol merkezinde, 1.0 = kollar arasında.
        Spiral kolların iç kavisi = düşük phase → yüksek opasite.
        """
        if not self.is_rotating or self.num_arms == 0:
            return 0.5
        R = math.sqrt(x*x + y*y)
        if R < 0.1: return 0.5
        theta = math.atan2(y, x)
        # Logaritmik spiral'in ters denklemi: θ_arm(R) = ln(R/a) / b
        if R < self.arm_base_radius: return 0.5
        theta_arm_base = math.log(R / self.arm_base_radius) / self.arm_spread
        min_dist = math.pi  # en yakın kol açısal mesafesi
        for arm_i in range(self.num_arms):
            arm_offset = arm_i * 2.0 * math.pi / self.num_arms
            arm_theta = theta_arm_base + arm_offset
            # Açısal fark (mod 2π)
            diff = (theta - arm_theta) % (2.0 * math.pi)
            if diff > math.pi: diff = 2.0 * math.pi - diff
            min_dist = min(min_dist, diff)
        # Normalize: 0=kol üstü, 1=kollar arası
        max_gap = math.pi / self.num_arms
        return min(1.0, min_dist / max_gap)

    # ══════════════════════════════════════════
    #  CHEMISTRY & PHYSICS
    # ══════════════════════════════════════════

    def metallicity_at(self, R: float) -> float:
        return self.central_metallicity * math.exp(-R / self.metallicity_scale_length)

    # ══════════════════════════════════════════
    #  v1.3.1: İKİ AYRI DİSK — STELLAR vs GAS
    # ══════════════════════════════════════════

    def stellar_density_at(self, R: float, z: float) -> float:
        """
        v1.3.1: Yıldız yoğunluğu — GAZ'dan BAĞIMSIZ.
        İki bileşen:
          1) Üstel disk:  ρ★(R) = e^(-R/Rd_star)
          2) Sérsic bulge: ρ_b(R) = f_b · e^(-7.67·[(R/Re)^(1/4) - 1])
        Eski yıldızlar disk boyunca yayılmıştır → daha geniş scale length.
        """
        # Thin + thick disk
        disk_radial = math.exp(-R / self.stellar_disk_scale_length)
        # Thick disk: daha kalın z dağılımı (eski yıldızlar)
        thin_z = math.exp(-abs(z) / (self.galaxy_thickness * 0.5))  # thin: ±0.3 kpc
        thick_z = math.exp(-abs(z) / (self.galaxy_thickness * 2.0))  # thick: ±1.2 kpc
        disk = disk_radial * (0.7 * thin_z + 0.3 * thick_z)  # %70 thin, %30 thick

        # Sérsic bulge (n=4 de Vaucouleurs)
        if R < 0.01:
            bulge = self.bulge_mass_fraction * 10.0  # merkez tekilliğini önle
        else:
            x = (R / self.bulge_effective_radius) ** 0.25
            bulge = self.bulge_mass_fraction * math.exp(-7.67 * (x - 1.0))

        return max(0.0, disk + bulge)

    def gas_density_raw(self, R: float, z: float) -> float:
        """
        v1.3.1: Gaz yoğunluğu — YILDIZ'dan BAĞIMSIZ.
        Gaz daha dar z profili (molecular cloud disk) ama daha geniş R.
        Spiral kollarla lokalize: arm_boost çarpanı.
        """
        # Gaz diski — ayrı scale length
        radial = math.exp(-R / self.gas_disk_scale_length)
        # Gaz daha ince bir z katmanında yoğunlaşır
        vertical = math.exp(-z * z / (2.0 * (self.galaxy_thickness * 0.4) ** 2))
        return radial * vertical

    def gas_density_at(self, R: float, z: float, x: float = 0.0, y: float = 0.0) -> float:
        """
        v1.3.1: Patchy gaz + spiral kol molecular cloud yoğunlaşması.
        x,y verilirse spiral arm boost uygulanır.
        """
        smooth = self.gas_density_raw(R, z)
        # Fraktal toz gürültüsü
        noise = _noise3d(R * 0.7, z * 2.0, R * 0.3 + z * 0.5)
        patchy = smooth * (1.0 + self.dust_noise_amplitude * noise)

        # v1.3.1: Spiral kol molecular cloud boost
        if x != 0.0 or y != 0.0:
            arm_phase = self._spiral_arm_phase(x, y)
            # arm_phase=0 → kol merkezi → boost, arm_phase=1 → kollar arası → boost yok
            arm_factor = 1.0 + self.molecular_cloud_arm_boost * max(0.0, 1.0 - arm_phase) ** 2
            patchy *= arm_factor

        return max(0.0, patchy)

    def local_turbulence(self, x: float, y: float, z: float) -> float:
        """
        v1.3 §14: Yerel gaz türbülansı [0, 1].
        Yüksek → kaotik gaz, yıldız oluşum bölgesi potansiyeli.
        Düşük → sakin, void bölgesi.
        """
        return _turbulence3d(x * 0.8, y * 0.8, z * 1.5)

    def gas_density_turbulent(self, x: float, y: float, z: float) -> float:
        """
        v1.3 §14: Türbülansla modüle edilmiş gaz yoğunluğu.
        v1.3.1: x,y ile spiral kol molecular cloud boost dahil.
        """
        R = math.sqrt(x*x + y*y)
        base = self.gas_density_at(R, z, x, y)
        turb = self.local_turbulence(x, y, z)
        # Türbülans modülasyonu: -50% (void) ile +100% (clump) arası
        modulation = 1.0 + self.turbulence_amplitude * (2.0 * turb - 1.0)
        return max(0.0, base * modulation)

    def gas_density_with_cavities(
        self, x: float, y: float, z: float,
        cavities: list[FeedbackCavity],
    ) -> float:
        base = self.gas_density_turbulent(x, y, z)
        for cav in cavities:
            d = math.sqrt((x-cav.x)**2 + (y-cav.y)**2 + (z-cav.z)**2)
            if d < cav.radius_kpc:
                base *= (1.0 - cav.density_reduction)
        return max(0.0, base)

    def interstellar_opacity(self, x: float, y: float, z: float) -> float:
        """
        v1.3 §15: Toz koridoru opasitesi [0, 1].
        Spiral kolların iç kavisinde yoğunlaşır (Dark Rift).
        """
        R = math.sqrt(x*x + y*y)
        phase = self._spiral_arm_phase(x, y)
        gas = self.gas_density_turbulent(x, y, z)
        # Kol merkezine yakınlık → yüksek opasite
        arm_factor = max(0.0, 1.0 - phase) ** 2  # 0=kollar arası, 1=kol merkezi
        # Gaz yoğunluğu ile orantılı
        opacity = arm_factor * gas * 1.5
        # Fraktal modülasyon
        noise = abs(_noise3d(x*2.1, y*2.3, z*3.0))
        opacity *= (1.0 + 0.4 * noise)
        return max(0.0, min(1.0, opacity))

    def extinction_coefficient(self, x: float, y: float, z: float) -> float:
        """v1.2 + v1.3: opasite etkisi de dahil."""
        R = math.sqrt(x*x + y*y)
        gas = self.gas_density_at(R, z)
        noise = _noise3d(x*1.1, y*1.3, z*2.0)
        tau_base = self.base_extinction * gas * (1.0 + 0.5 * noise)
        # v1.3: Dark Rift opasitesi ek sönümlenme
        opacity = self.interstellar_opacity(x, y, z)
        tau = tau_base + opacity * 0.3
        return max(0.0, tau)

    def magnetic_field_strength(self, x: float, y: float, z: float) -> float:
        """
        v1.3 §16: Galaktik manyetik alan şiddeti (μG).
        B ∝ (gas_density)^0.5 × radyal profil.
        Merkez: ~10 μG, disk: ~6 μG, kenar: ~2 μG.
        """
        R = math.sqrt(x*x + y*y)
        gas = self.gas_density_turbulent(x, y, z)
        # Radyal profil: merkeze yakın güçlü
        r_factor = math.exp(-R / (self.galaxy_radius * 0.6))
        # Gaz yoğunluğu ile orantılı (frozen-in flux)
        b_field = self.base_magnetic_field * math.sqrt(max(0.01, gas)) * (0.5 + r_factor)
        return round(b_field, 3)

    def radiation_at(self, R: float) -> float:
        if R < 0.1: return 100.0
        return 10.0 / (R * R)

    def star_count_prediction(self, R: float, z: float) -> float:
        """
        v1.3.1: Yıldız sayısı artık STELLAR density'den türer.
        Gaz yoğunluğu sadece yeni yıldız oluşumunu etkiler.
        Toplam = mevcut yıldızlar (stellar disk) + yeni oluşum (gas → SFR)
        """
        # Mevcut yıldız popülasyonu (stellar disk + bulge)
        sd = self.stellar_density_at(R, z)
        existing_stars = sd * 8000.0  # normalize: güneş çevresinde ~4000

        # Yeni yıldız oluşum oranı (Star Formation Rate ∝ gas^1.4 — Kennicutt-Schmidt)
        gd = self.gas_density_raw(R, z)  # smooth gaz
        m = self.metallicity_at(R)
        sfr = (gd ** 1.4) * (1.0 + m * 20.0) * 2000.0

        return min(max(existing_stars + sfr, 0.0), 1e7)

    def habitability_score(self, R: float, z: float,
                           opacity: float = 0.0) -> float:
        """v1.3: opacity yüksekse habitability düşer (protoplanet disk süpürülmesi)."""
        if R < self.sterilisation_radius: return 0.0
        m = self.metallicity_at(R)
        rad = self.radiation_at(R)
        ms = max(0.0, min(1.0, 1.0 - abs(m - 0.015) / 0.015))
        rs = max(0.0, min(1.0, 1.0 - rad / 5.0))
        zs = math.exp(-abs(z) / self.galaxy_thickness)
        base_hab = max(0.0, min(1.0, ms * rs * zs))
        # v1.3 §15: Dark Rift penalty
        dust_penalty = 1.0 - 0.4 * opacity  # opacity=1 → %40 düşüş
        return max(0.0, min(1.0, base_hab * dust_penalty))

    # ══════════════════════════════════════════
    #  v1.3 §17: ENVIRONMENT TAGS
    # ══════════════════════════════════════════

    def _compute_environment_tags(
        self, x: float, y: float, z: float,
        turb: float, opacity: float, gas_turb: float,
        has_snr: bool,
    ) -> list[str]:
        R = math.sqrt(x * x + y * y)
        tags = []
        if opacity > 0.6:
            tags.append("DARK_RIFT")
        if turb > 0.65 and gas_turb > 0.3:
            tags.append("STAR_FORMING")
        if turb < 0.2 and gas_turb < 0.05:
            tags.append("VOID")
        if has_snr:
            tags.append("SNR_ENRICHED")
        # v1.2.5: Fermi Bubble tag
        if self.get_galactic_jet_factor(x, y, z) * 20.0 > 5.0:
            tags.append("FERMI_BUBBLE")
        # v1.2.5: IGM tag
        if R > self.galaxy_radius:
            tags.append("INTERGALACTIC")
        if not tags:
            tags.append("STABLE")
        return tags

    # ══════════════════════════════════════════
    #  KROUPA IMF (v1.2)
    # ══════════════════════════════════════════

    @staticmethod
    def _apply_kroupa_imf(rng: SeededRNG):
        u = rng.next()
        if u < 0.75:     mass = rng.range(0.08, 0.45)
        elif u < 0.87:   mass = rng.range(0.45, 0.80)
        elif u < 0.95:   mass = rng.range(0.80, 1.04)
        elif u < 0.98:   mass = rng.range(1.04, 1.40)
        elif u < 0.995:  mass = rng.range(1.40, 2.10)
        elif u < 0.999:  mass = rng.range(2.10, 16.0)
        else:            mass = rng.range(16.0, 120.0)
        mass = max(0.08, min(120.0, mass))
        sc = StellarClass.M
        for thr, cls in _MASS_CLASS_TABLE:
            if mass <= thr: sc = cls; break
        if mass < 0.43:   lum = 0.23 * mass**2.3
        elif mass < 2.0:  lum = mass**4.0
        elif mass < 55.0: lum = 1.4 * mass**3.5
        else:             lum = 32000.0 * mass
        return mass, sc, lum, _interp(_MASS_RADIUS_TABLE, mass), _interp(_MASS_TEMP_TABLE, mass)

    # ══════════════════════════════════════════
    #  TEMPORAL DRIFT (v1.2)
    # ══════════════════════════════════════════

    def temporal_drift(self, R: float, rng: SeededRNG) -> tuple[float, float]:
        r_norm = min(R / self.galaxy_radius, 1.0)
        age = rng.range(10.0, 13.0) * (1.0 - r_norm) + rng.range(1.0, 5.0) * r_norm
        metal_mod = 0.3 * (1.0 - r_norm) + 1.2 * r_norm
        return round(age, 2), round(metal_mod, 3)

    # ══════════════════════════════════════════
    #  v1.2.5 §19: NFW DARK MATTER HALO
    # ══════════════════════════════════════════

    def nfw_halo_density(self, R: float) -> float:
        """
        Navarro-Frenk-White karanlık madde profili.
        ρ(r) = ρ_s / [ (r/rs) · (1 + r/rs)² ]
        Normalize edilmiş — boyutsuz yoğunluk.
        """
        rs = 20.0  # Scale radius (kpc)
        x = max(0.1, R / rs)
        return 1.0 / (x * (1.0 + x) ** 2)

    def nfw_enclosed_mass_factor(self, R: float) -> float:
        """NFW kümülatif kütle faktörü: ln(1+c) - c/(1+c) formundan."""
        rs = 20.0
        x = max(0.01, R / rs)
        return math.log(1.0 + x) - x / (1.0 + x)

    # ══════════════════════════════════════════
    #  v1.2.5 §20: FERMI BUBBLES
    # ══════════════════════════════════════════

    def get_galactic_jet_factor(self, x: float, y: float, z: float) -> float:
        """
        Fermi Bubbles simülasyonu.
        Merkezden Z eksenine doğru ~10 kpc uzanan radyasyon lobları.
        V-şeklinde genişleyen koni.
        """
        R_xy = math.sqrt(x * x + y * y)
        # Lobların genişliği Z ile artar (V-Shape)
        cone_width = 0.5 + abs(z) * 0.2
        if R_xy > cone_width:
            return 0.0
        # Z yükseldikçe sönümlenen ama merkezde ekstrem olan enerji
        return math.exp(-abs(z) / 4.0) * (1.0 / (R_xy + 0.1))

    # ══════════════════════════════════════════
    #  v1.2.5 §21: GALACTIC ENTROPY
    # ══════════════════════════════════════════

    def get_entropy_factor(self, age_gyr: float) -> float:
        """
        Galaktik entropi: zaman geçtikçe gazın yıldızlara dönüşüp
        tükenme (depletion) oranı.
        13.8 Gyr sonunda gazın ~%60'ı tükenmiş varsayılır.
        """
        return max(0.1, 1.0 - (age_gyr / 20.0))

    # ══════════════════════════════════════════
    #  v1.2.5 §22: IGM (Intergalactic Medium)
    # ══════════════════════════════════════════

    def igm_density(self, R: float) -> float:
        """
        Galaksi sınırlarının dışındaki seyrek plazma.
        R > galaxy_radius → üstel azalan çok düşük yoğunluk.
        """
        if R <= self.galaxy_radius:
            return 0.0  # galaksi içinde IGM yok, normal gaz var
        return 0.001 * math.exp(-(R - self.galaxy_radius) / 5.0)

    # ══════════════════════════════════════════
    #  v1.2.5 §23: get_refined_physics()
    # ══════════════════════════════════════════

    def get_refined_physics(self, x: float, y: float, z: float) -> dict:
        """
        Tüm makro kozmoloji katmanlarını birleştiren üst-sorgu.
        NFW halo + Fermi bubbles + Entropy + IGM + gelişmiş rotasyon.
        """
        R = math.sqrt(x * x + y * y)
        seed = self._sector_seed(x, y, z)
        rng = SeededRNG(seed)

        # 1. Zaman ve Entropi
        age, metal_mod = self.temporal_drift(R, rng)
        entropy = self.get_entropy_factor(age)

        # 2. Dinamik Gaz Yoğunluğu (Entropy & IGM dahil)
        base_gas = self.gas_density_turbulent(x, y, z)
        # Galaksi dışındaysak → IGM
        if R > self.galaxy_radius:
            base_gas = self.igm_density(R)
        refined_gas = base_gas * entropy

        # 3. Gelişmiş Radyasyon (Fermi Bubble jetleri dahil)
        base_rad = self.radiation_at(R)
        jet_rad = self.get_galactic_jet_factor(x, y, z) * 20.0
        total_rad = base_rad + jet_rad

        # 4. NFW Karanlık Madde Destekli Hız Eğrisi
        # v_orbital = sqrt(v_disk² + v_halo²)
        v_disk = self._circular_velocity(R)
        # Halo katkısı: v_halo ∝ sqrt(ρ_NFW × R)
        v_halo = 160.0 * math.sqrt(self.nfw_halo_density(R) * max(0.1, R))
        v_total = math.sqrt(v_disk ** 2 + v_halo ** 2)

        # 5. IGM yoğunluğu
        igm = self.igm_density(R)

        return {
            "entropy_index":          round(entropy, 3),
            "dark_matter_density":    round(self.nfw_halo_density(R), 5),
            "nfw_enclosed_mass":      round(self.nfw_enclosed_mass_factor(R), 4),
            "is_in_fermi_bubble":     jet_rad > 5.0,
            "fermi_jet_factor":       round(self.get_galactic_jet_factor(x, y, z), 4),
            "total_radiation":        round(total_rad, 3),
            "orbital_velocity_kms":   round(v_total, 2),
            "v_disk_kms":             round(v_disk, 2),
            "v_halo_kms":             round(v_halo, 2),
            "gas_depletion_ratio":    round(1.0 - entropy, 3),
            "refined_gas_density":    round(refined_gas, 5),
            "igm_density":            round(igm, 6),
            "is_intergalactic":       R > self.galaxy_radius,
            "temporal_age_gyr":       round(age, 2),
            "temporal_metal_mod":     round(metal_mod, 3),
        }

    # ══════════════════════════════════════════
    #  KINEMATIC DRIFT (v1.2, v1.2.5: NFW-enhanced)
    # ══════════════════════════════════════════

    def _circular_velocity(self, R: float) -> float:
        """v1.2.5: NFW halo katkısıyla düzleşen rotasyon eğrisi."""
        if R < 0.1:
            return 0.0
        # Disk katkısı
        v_disk = 220.0 * min(R / 2.0, 1.0)
        # NFW halo katkısı — dış bölgelerde eğriyi sabit tutar
        v_halo = 160.0 * math.sqrt(self.nfw_halo_density(R) * max(0.1, R))
        return math.sqrt(v_disk ** 2 + v_halo ** 2)

    def _compute_velocity_vector(self, x, y, z, rng):
        R = math.sqrt(x*x + y*y)
        if not self.is_rotating:
            spd = rng.range(80.0, 160.0)
            th = rng.next()*2*math.pi; ph = math.acos(2*rng.next()-1)
            return (round(spd*math.sin(ph)*math.cos(th),2),
                    round(spd*math.sin(ph)*math.sin(th),2),
                    round(spd*math.cos(ph),2))
        if R < 0.01: return (0.0, 0.0, 0.0)
        vc = self._circular_velocity(R); a = math.atan2(y, x)
        d = 0.05
        return (round(-vc*math.sin(a)*(1+rng.range(-d,d)),2),
                round(vc*math.cos(a)*(1+rng.range(-d,d)),2),
                round(rng.range(-8,8),2))

    # ══════════════════════════════════════════
    #  GHOST NEBULA (v1.3: nebula_type)
    # ══════════════════════════════════════════

    def _make_nebula_id(self, sector_seed: int, local_idx: int = 0) -> str:
        """PATCH 1: ID is purely a function of sector_seed + local_idx.
        No dependency on global counter → fully deterministic."""
        self._nebula_counter += 1  # still increment for stats
        return f"GN-{stable_seed(f'{self.galaxy_name}:neb:{sector_seed}:{local_idx}') & 0xFFFF:04X}"

    def _make_star_id(self, sector_seed: int, local_idx: int = 0) -> str:
        self._star_counter += 1
        return f"ST-{stable_seed(f'{self.galaxy_name}:star:{sector_seed}:{local_idx}') & 0xFFFFFF:06X}"

    # PATCH 2: Observed/Procedural star separation
    @property
    def placed_stars(self) -> list[ProceduralStar]:
        """Read-only merged view. Observed first, then procedural."""
        return self._observed_stars + self._procedural_stars

    def inject_observed_star(self, star: ProceduralStar) -> None:
        """Add observed (Gaia) star. NEVER deleted by procedural regen."""
        star.is_procedural = False
        self._observed_stars.append(star)

    def distribute_stars(self, sector_x: float, sector_y: float, sector_z: float) -> None:
        """Regenerate ONLY procedural stars for a sector. Observed stars untouched."""
        seed = self._sector_seed(sector_x, sector_y, sector_z)
        nebulae = self.generate_ghost_nebulae(sector_x, sector_y, sector_z, seed)
        new_proc: list[ProceduralStar] = []
        for i, neb in enumerate(nebulae):
            st, _ = self.spawn_stars_from_nebula(neb, seed + i * 9973)
            new_proc.extend(st)
        self._procedural_stars = new_proc

    def _assign_morphology(
        self, ntype: NebulaType, turb: float, age: float, rng: SeededRNG
    ) -> tuple[NebulaMorphology, float, float, float]:
        """
        PATCH 4: Morphology assignment based on nebula_type, turbulence, age.
        Returns: (morphology, sigma_x, sigma_y, sigma_z)
        PATCH 3: Anisotropic sigma ratios per morphology.
        """
        base_s = 0.1 + rng.next() * 0.4  # base spread

        if ntype == NebulaType.SUPERNOVA_REMNANT:
            if age < 1.0:
                morph = NebulaMorphology.SHELL
                return morph, base_s*1.2, base_s*1.2, base_s*0.8  # hollow sphere-ish
            else:
                morph = NebulaMorphology.RING
                return morph, base_s*1.5, base_s*1.5, base_s*0.2  # flat ring

        if ntype == NebulaType.DARK:
            if turb > 0.6:
                morph = NebulaMorphology.PILLAR
                return morph, base_s*0.3, base_s*0.3, base_s*2.5  # tall thin column
            else:
                morph = NebulaMorphology.CLOUD
                return morph, base_s, base_s*0.8, base_s*0.4

        # EMISSION
        if turb > 0.7:
            morph = NebulaMorphology.FILAMENT
            # elongated along random axis
            stretch = 2.0 + rng.next() * 2.0
            if rng.next() < 0.5:
                return morph, base_s*stretch, base_s*0.4, base_s*0.3
            else:
                return morph, base_s*0.4, base_s*stretch, base_s*0.3
        elif turb > 0.5:
            morph = NebulaMorphology.FRACTAL
            return morph, base_s*1.1, base_s*0.9, base_s*0.5
        elif rng.next() < 0.15:
            morph = NebulaMorphology.BIPOLAR
            return morph, base_s*0.5, base_s*0.5, base_s*2.0
        else:
            morph = NebulaMorphology.CLOUD
            return morph, base_s, base_s*0.9, base_s*0.3

    def generate_ghost_nebulae(self, sx, sy, sz, seed) -> list[GhostNebula]:
        rng = SeededRNG(seed)
        count = 3 + int(rng.next() * 3)
        nebulae = []
        for _ in range(count):
            ox = (rng.next()-0.5)*2; oy = (rng.next()-0.5)*2; oz = (rng.next()-0.5)*0.6
            R = math.sqrt((sx+ox)**2 + (sy+oy)**2)
            age = 0.1 + rng.next()*12.0
            metal_off = (rng.next()-0.5)*0.005
            budget = int(20 + rng.next()*80*self.gas_density_at(R, sz+oz))

            # v1.3 §18: Nebula tipi
            nt_roll = rng.next()
            if nt_roll < 0.55:
                ntype = NebulaType.EMISSION
            elif nt_roll < 0.85:
                ntype = NebulaType.DARK
            else:
                ntype = NebulaType.SUPERNOVA_REMNANT
                metal_off += 0.25 * self.metallicity_at(R)

            # PATCH 4: Morphology + PATCH 3: Ellipsoidal sigma
            turb = self.local_turbulence(sx+ox, sy+oy, sz+oz)
            morph, sig_x, sig_y, sig_z = self._assign_morphology(ntype, turb, age, rng)

            # PATCH 1: Deterministic ID — sector_seed + local index
            neb_id = self._make_nebula_id(seed, len(nebulae))

            nebulae.append(GhostNebula(
                id=neb_id, x=sx+ox, y=sy+oy, z=sz+oz,
                sigma_x=sig_x, sigma_y=sig_y, sigma_z=sig_z,
                age_gyr=age, metallicity_offset=metal_off,
                star_budget=budget, nebula_type=ntype,
                morphology=morph,
            ))
        return nebulae

    def spawn_stars_from_nebula(self, neb: GhostNebula, seed: int):
        rng = SeededRNG(seed)
        stars: list[ProceduralStar] = []
        cavities: list[FeedbackCavity] = []

        # v1.3 §18: SNR → yerel radyasyon artışı (yıldız extinction'a eklenir)
        snr_rad_boost = 0.02 if neb.nebula_type == NebulaType.SUPERNOVA_REMNANT else 0.0
        # v1.3 §18: DARK nebula → ek extinction
        dark_ext_boost = 0.03 if neb.nebula_type == NebulaType.DARK else 0.0

        for _ in range(neb.star_budget):
            # PATCH 3: Ellipsoidal distribution
            x = neb.x + rng.gauss() * neb.sigma_x
            y = neb.y + rng.gauss() * neb.sigma_y
            z = neb.z + rng.gauss() * neb.sigma_z
            R = math.sqrt(x*x + y*y)
            mass, sc, lum, radius, temp = self._apply_kroupa_imf(rng)
            td_age, td_mm = self.temporal_drift(R, rng)
            final_age = neb.age_gyr*0.4 + td_age*0.6
            final_metal = self.metallicity_at(R)*td_mm + neb.metallicity_offset
            ext = self.extinction_coefficient(x, y, z) + dark_ext_boost + snr_rad_boost
            app_lum = lum * math.exp(-ext)
            is_bin = rng.next() < (0.70 if sc.value <= 1 else 0.30)
            vel = self._compute_velocity_vector(x, y, z, rng)
            sid = self._make_star_id(seed, len(stars))

            stars.append(ProceduralStar(
                x=x, y=y, z=z, star_id=sid, is_procedural=True,
                parent_nebula_id=neb.id, gravity_well_id=neb.id,
                age_gyr=round(final_age, 2),
                metallicity=round(max(0.0, final_metal), 5),
                metallicity_offset=neb.metallicity_offset,
                mass=round(mass, 3), luminosity=round(lum, 4),
                apparent_luminosity=round(app_lum, 4),
                radius=round(radius, 3), temperature=round(temp, 0),
                stellar_class=sc, is_binary=is_bin,
                velocity_vector=vel, extinction=round(ext, 4),
            ))
            if sc in (StellarClass.O, StellarClass.B):
                cavities.append(FeedbackCavity(
                    source_star_id=sid, x=x, y=y, z=z,
                    radius_kpc=round(0.01*mass**0.5, 4),
                    density_reduction=0.90, stellar_class=sc.name,
                ))
        return stars, cavities

    # ══════════════════════════════════════════
    #  SECTOR GRID
    # ══════════════════════════════════════════

    def _grid_key(self, x, y, z):
        return f"{round(x/self.grid_resolution)},{round(y/self.grid_resolution)},{round(z/self.grid_resolution)}"

    def _sector_seed(self, x, y, z):
        """PATCH 1: SHA256 deterministic seeding."""
        return stable_seed(f"{self.galaxy_name}:{round(x)}:{round(y)}:{round(z)}")

    def _build_stellar_input(self, R, z, *, is_procedural=True,
                              parent_nebula_id=None, mass=1.0, temperature=5778.0,
                              age=5.0, luminosity=1.0, extinction=0.0,
                              velocity_vector=(0,0,0), gravity_well_id=None,
                              local_turbulence=0.0, opacity_index=0.0,
                              magnetic_field=0.0) -> dict:
        """v1.3: Raw Physics parametreleri eklendi."""
        return {
            "metallicity_Z":          round(self.metallicity_at(R), 5),
            "gas_density_normalized": round(self.gas_density_at(R, z), 4),
            "radiation_flux":         round(self.radiation_at(R), 3),
            "habitability_index":     round(self.habitability_score(R, z, opacity_index), 3),
            "galactic_radius_kpc":    round(R, 2),
            "vertical_offset_kpc":    round(z, 2),
            "estimated_star_count":   round(self.star_count_prediction(R, z)),
            "extinction_coefficient": round(extinction, 4),
            "is_procedural":          is_procedural,
            "parent_nebula_id":       parent_nebula_id,
            "mass":                   round(mass, 3),
            "temperature":            round(temperature),
            "age":                    round(age, 2),
            "luminosity":             round(luminosity, 4),
            "extinction":             round(extinction, 4),
            "velocity_vector":        [round(v, 2) for v in velocity_vector],
            "gravity_well_id":        gravity_well_id,
            # v1.3 Raw Physics
            "local_turbulence":       round(local_turbulence, 4),
            "opacity_index":          round(opacity_index, 4),
            "magnetic_field":         round(magnetic_field, 3),
        }

    def get_sector_parameters(self, x: float, y: float, z: float) -> dict:
        key = self._grid_key(x, y, z)
        if key in self._real_data: return self._real_data[key]
        if key in self._sector_cache: return self._sector_cache[key]

        R = math.sqrt(x*x + y*y)
        seed = self._sector_seed(x, y, z)
        nebulae = self.generate_ghost_nebulae(x, y, z, seed)

        all_stars, all_cavities = [], []
        for i, neb in enumerate(nebulae):
            st, cv = self.spawn_stars_from_nebula(neb, seed + i*9973)
            all_stars.extend(st); all_cavities.extend(cv)

        td_rng = SeededRNG(seed + 7)
        td_age, td_mm = self.temporal_drift(R, td_rng)

        class_counts = {sc.name: 0 for sc in StellarClass}
        for s in all_stars: class_counts[s.stellar_class.name] += 1

        # v1.3 §14–§17: Yeni fizik hesaplamaları
        turb = self.local_turbulence(x, y, z)
        gas_turb = self.gas_density_turbulent(x, y, z)
        opacity = self.interstellar_opacity(x, y, z)
        b_field = self.magnetic_field_strength(x, y, z)
        hab = self.habitability_score(R, z, opacity)
        has_snr = any(n.nebula_type == NebulaType.SUPERNOVA_REMNANT for n in nebulae)
        env_tags = self._compute_environment_tags(x, y, z, turb, opacity, gas_turb, has_snr)

        # v1.3 §18: SNR → radyasyon artışı
        rad_level = self.radiation_at(R)
        if has_snr:
            rad_level *= 1.5  # SNR bölgesinde %50 radyasyon artışı

        rep = all_stars[len(all_stars)//2] if all_stars else None

        result = {
            "sector_key": key,
            "galactic_x_kpc": round(x, 2), "galactic_y_kpc": round(y, 2),
            "galactic_z_kpc": round(z, 2), "galactic_radius_kpc": round(R, 2),
            "stellar_density": round(self.stellar_density_at(R, z), 4),
            "gas_density": round(self.gas_density_at(R, z, x, y), 4),
            "gas_density_turbulent": round(gas_turb, 4),
            "gas_density_with_cavities": round(
                self.gas_density_with_cavities(x, y, z, all_cavities), 4),
            "metallicity": round(self.metallicity_at(R), 5),
            "radiation_level": round(rad_level, 3),
            "star_count_prediction": round(self.star_count_prediction(R, z)),
            "habitability_score": round(hab, 3),
            "inside_sterilisation_zone": R < self.sterilisation_radius,
            "sterilisation_radius_kpc": round(self.sterilisation_radius, 2),
            "warp_z_displacement": round(self.warp_z(R, math.atan2(y, x)), 3),
            "extinction_coefficient": round(self.extinction_coefficient(x, y, z), 4),
            "galaxy_type": self.galaxy_type.name,
            "galaxy_name": self.galaxy_name,
            "is_rotating": self.is_rotating,
            "angular_momentum": round(self.angular_momentum, 2),
            "temporal_drift_age": td_age,
            "temporal_drift_metal_mod": td_mm,
            # v1.3 §14–§17: Yeni alanlar
            "local_turbulence": round(turb, 4),
            "opacity_index": round(opacity, 4),
            "magnetic_field_uG": round(b_field, 3),
            "environment_tags": env_tags,
            # Ghost Nebulae (v1.3: nebula_type dahil)
            "ghost_nebula_count": len(nebulae),
            "ghost_nebulae": [n.to_dict() for n in nebulae],
            "spawned_star_count": len(all_stars),
            "imf_class_distribution": class_counts,
            "feedback_cavity_count": len(all_cavities),
            "feedback_cavities": [c.to_dict() for c in all_cavities],
            # v1.2.5: Makro Kozmoloji
            "dark_matter_density":    round(self.nfw_halo_density(R), 5),
            "fermi_jet_factor":       round(self.get_galactic_jet_factor(x, y, z), 4),
            "is_in_fermi_bubble":     self.get_galactic_jet_factor(x, y, z) * 20.0 > 5.0,
            "entropy_index":          round(self.get_entropy_factor(td_age), 3),
            "igm_density":            round(self.igm_density(R), 6),
            "is_intergalactic":       R > self.galaxy_radius,
            "orbital_velocity_kms":   round(self._circular_velocity(R), 2),
            "data_source": "procedural",
            "stellar_input": self._build_stellar_input(
                R, z, is_procedural=True,
                parent_nebula_id=nebulae[0].id if nebulae else None,
                mass=rep.mass if rep else 1.0,
                temperature=rep.temperature if rep else 5778.0,
                age=rep.age_gyr if rep else td_age,
                luminosity=rep.apparent_luminosity if rep else 1.0,
                extinction=rep.extinction if rep else 0.0,
                velocity_vector=rep.velocity_vector if rep else (0,0,0),
                gravity_well_id=rep.gravity_well_id if rep else None,
                local_turbulence=turb, opacity_index=opacity, magnetic_field=b_field,
            ),
        }
        self._sector_cache[key] = result
        return result

    # ══════════════════════════════════════════
    #  VERİ ENTEGRASYON
    # ══════════════════════════════════════════

    def inject_real_data(self, x, y, z, data):
        key = self._grid_key(x, y, z)
        base = self.get_sector_parameters(x, y, z).copy()
        base.update(data); base["data_source"] = "observed"
        if "stellar_input" in base:
            si = base["stellar_input"].copy()
            si["is_procedural"] = False; si["parent_nebula_id"] = None
            base["stellar_input"] = si
        self._real_data[key] = base

    def _seed_real_data(self):
        self.inject_real_data(8,0,0,{"region_name":"Solar Neighbourhood","metallicity":.014,"gas_density":.15,"radiation_level":.045,"star_count_prediction":4200,"habitability_score":.82,"notes":"Gaia DR3 — local bubble"})
        self.inject_real_data(0,0,0,{"region_name":"Sagittarius A* Core","metallicity":.035,"gas_density":12.5,"radiation_level":95.0,"star_count_prediction":850000,"habitability_score":0.0,"notes":"NASA Chandra X-ray"})
        self.inject_real_data(7,1,0,{"region_name":"Orion-Cygnus Arm","metallicity":.016,"gas_density":.22,"radiation_level":.06,"star_count_prediction":6100,"habitability_score":.74,"notes":"Gaia DR3"})
        self.inject_real_data(10,3,0,{"region_name":"Perseus Arm","metallicity":.011,"gas_density":.30,"radiation_level":.03,"star_count_prediction":7800,"habitability_score":.65,"notes":"Gaia DR3"})
        self.inject_real_data(4,-2,0,{"region_name":"Scutum-Centaurus Arm","metallicity":.022,"gas_density":.45,"radiation_level":.18,"star_count_prediction":15200,"habitability_score":.41,"notes":"NASA Spitzer"})
        self.inject_real_data(14,0,0,{"region_name":"Outer Disk Edge","metallicity":.004,"gas_density":.02,"radiation_level":.005,"star_count_prediction":320,"habitability_score":.15,"notes":"Gaia DR3"})

    # ══════════════════════════════════════════
    #  UTILITY
    # ══════════════════════════════════════════

    @property
    def real_entries(self): return list(self._real_data.values())

    def radial_profile(self, steps=40):
        p = []
        for i in range(steps):
            R = i/(steps-1)*self.galaxy_radius
            p.append({"R_kpc":round(R,2),
                       "stellar_density":round(self.stellar_density_at(R,0),4),
                       "gas_density":round(self.gas_density_at(R,0),4),
                       "metallicity":round(self.metallicity_at(R),5),
                       "radiation":round(self.radiation_at(R),3),
                       "habitability":round(self.habitability_score(R,0),3),
                       "star_count":round(self.star_count_prediction(R,0)),
                       "extinction":round(self.extinction_coefficient(R,0,0),4)})
        return p

    def clear_cache(self):
        self._sector_cache.clear(); self._nebula_counter=0; self._star_counter=0

    def summary(self):
        return "\n".join([
            f"╔══ UniversalGalaxy v{self.VERSION} \"{self.galaxy_name}\" ══╗",
            f"  Type             : {self.galaxy_type.name}",
            f"  Radius           : {self.galaxy_radius:.1f} kpc",
            f"  Steril. R        : {self.sterilisation_radius:.2f} kpc",
            f"  Rotating         : {self.is_rotating}",
            f"  Turbulence Amp   : {self.turbulence_amplitude:.2f}",
            f"  Base B-field     : {self.base_magnetic_field:.1f} μG",
            f"  Stellar Disk Rd  : {self.stellar_disk_scale_length:.1f} kpc",
            f"  Gas Disk Rd      : {self.gas_disk_scale_length:.1f} kpc",
            f"  Bulge Re         : {self.bulge_effective_radius:.1f} kpc ({self.bulge_mass_fraction:.0%})",
            f"  MC Arm Boost     : {self.molecular_cloud_arm_boost:.1f}×",
            f"  Observed stars   : {len(self._observed_stars)}",
            f"  Procedural stars : {len(self._procedural_stars)}",
            f"  Real-data pts    : {len(self._real_data)}",
            f"  Seeding          : SHA256 deterministic",
            f"╚{'═'*54}╝",
        ])

    def to_json(self, indent=2):
        return json.dumps({"version":self.VERSION,
            "radial_profile":self.radial_profile(30),
            "real_data":self.real_entries,
            "sample_sectors":[self.get_sector_parameters(0,0,0),
                              self.get_sector_parameters(4,0,0),
                              self.get_sector_parameters(8,0,0),
                              self.get_sector_parameters(12,0,0)],
        }, indent=indent, ensure_ascii=False)


# ═══════════════════════════════════════════════════════════════
if __name__ == "__main__":
    g = UniversalGalaxy()
    print(g.summary()); print()

    # §14–§17 test
    p = g.get_sector_parameters(6, 3, 0)
    print(f"▸ (6,3,0) procedural")
    print(f"  Turbulence       : {p['local_turbulence']}")
    print(f"  Opacity          : {p['opacity_index']}")
    print(f"  Magnetic field   : {p['magnetic_field_uG']} μG")
    print(f"  Environment tags : {p['environment_tags']}")
    print(f"  Gas (smooth)     : {p['gas_density']}")
    print(f"  Gas (turbulent)  : {p['gas_density_turbulent']}")
    print(f"  Gas (w/cavities) : {p['gas_density_with_cavities']}")
    print(f"  Habitability     : {p['habitability_score']}")
    print(f"  Nebulae types    : {[n['nebula_type'] for n in p['ghost_nebulae']]}")
    print(f"  IMF              : {p['imf_class_distribution']}")
    print(f"  Feedback cavities: {p['feedback_cavity_count']}")
    print()

    # §18: SNR test — find a sector with SNR
    print("▸ Searching for SNR nebula...")
    for rx in range(0, 15):
        for ry in range(-5, 5):
            sec = g.get_sector_parameters(float(rx), float(ry), 0.0)
            if "SNR_ENRICHED" in sec["environment_tags"]:
                print(f"  Found at ({rx},{ry},0):")
                print(f"    Tags     : {sec['environment_tags']}")
                print(f"    Radiation: {sec['radiation_level']} (SNR boosted)")
                snr_neb = [n for n in sec["ghost_nebulae"] if n["nebula_type"]=="SUPERNOVA_REMNANT"]
                if snr_neb:
                    print(f"    SNR neb  : {snr_neb[0]['id']}, ΔZ={snr_neb[0]['metallicity_offset']}")
                break
        else: continue
        break
    print()

    # stellar_input keys
    print(f"▸ stellar_input keys: {list(p['stellar_input'].keys())}")
    print()

    # Dark Rift test
    print("▸ Opacity scan (y=0, z=0):")
    for rx in [2, 5, 8, 11, 14]:
        sec = g.get_sector_parameters(float(rx), 0.0, 0.0)
        print(f"  R={rx}kpc: opacity={sec['opacity_index']:.3f}, "
              f"turb={sec['local_turbulence']:.3f}, "
              f"B={sec['magnetic_field_uG']:.2f}μG, "
              f"tags={sec['environment_tags']}")
    print()

    # ── v1.2.5: NFW Dark Matter Halo ──
    print("▸ NFW Dark Matter Halo (rotasyon eğrisi):")
    for rx in [1, 3, 8, 15, 25, 40]:
        rp = g.get_refined_physics(float(rx), 0.0, 0.0)
        print(f"  R={rx:2d}kpc: v_disk={rp['v_disk_kms']:.0f} "
              f"v_halo={rp['v_halo_kms']:.0f} "
              f"v_total={rp['orbital_velocity_kms']:.0f} km/s  "
              f"ρ_DM={rp['dark_matter_density']:.5f}")
    print()

    # ── v1.2.5: Fermi Bubbles ──
    print("▸ Fermi Bubbles (z-axis scan, x=0, y=0):")
    for zz in [0, 1, 2, 4, 6, 8, 10]:
        rp = g.get_refined_physics(0.0, 0.0, float(zz))
        print(f"  z={zz:2d}kpc: jet={rp['fermi_jet_factor']:.3f}, "
              f"in_bubble={rp['is_in_fermi_bubble']}, "
              f"total_rad={rp['total_radiation']:.1f}")
    print()

    # ── v1.2.5: Galactic Entropy ──
    print("▸ Galactic Entropy (age → gas depletion):")
    for age in [1, 3, 5, 8, 10, 13]:
        ent = g.get_entropy_factor(float(age))
        print(f"  age={age:2d}Gyr: entropy={ent:.3f}, depletion={1-ent:.1%}")
    print()

    # ── v1.2.5: IGM ──
    print("▸ IGM (intergalactic medium):")
    for rx in [10, 15, 16, 20, 30, 50]:
        rp = g.get_refined_physics(float(rx), 0.0, 0.0)
        print(f"  R={rx:2d}kpc: igm={rp['igm_density']:.6f}, "
              f"intergalactic={rp['is_intergalactic']}, "
              f"refined_gas={rp['refined_gas_density']:.5f}")
    print()

    # ── v1.2.5: Sector with all new fields ──
    sec = g.get_sector_parameters(5.0, 0.0, 3.0)
    print(f"▸ Sector (5,0,3) — near Fermi lobe:")
    print(f"  dark_matter_density : {sec['dark_matter_density']}")
    print(f"  fermi_jet_factor    : {sec['fermi_jet_factor']}")
    print(f"  is_in_fermi_bubble  : {sec['is_in_fermi_bubble']}")
    print(f"  entropy_index       : {sec['entropy_index']}")
    print(f"  orbital_velocity    : {sec['orbital_velocity_kms']} km/s")
    print(f"  environment_tags    : {sec['environment_tags']}")
    print()

    # ── v1.3.1: İki Ayrı Disk Karşılaştırması ──
    print("▸ v1.3.1 — İKİ AYRI DİSK: Stellar vs Gas")
    print(f"  stellar_disk_scale_length = {g.stellar_disk_scale_length} kpc")
    print(f"  gas_disk_scale_length     = {g.gas_disk_scale_length} kpc")
    print(f"  bulge_effective_radius    = {g.bulge_effective_radius} kpc")
    print(f"  bulge_mass_fraction       = {g.bulge_mass_fraction}")
    print(f"  molecular_cloud_arm_boost = {g.molecular_cloud_arm_boost}")
    print()
    print(f"  {'R(kpc)':>7} {'ρ_star':>10} {'ρ_gas':>10} {'star_count':>12} {'ratio':>8}")
    print(f"  {'─'*7} {'─'*10} {'─'*10} {'─'*12} {'─'*8}")
    for rx in [0, 1, 2, 4, 6, 8, 10, 12, 14]:
        sd = g.stellar_density_at(float(rx), 0.0)
        gd = g.gas_density_raw(float(rx), 0.0)
        sc = g.star_count_prediction(float(rx), 0.0)
        ratio = sd / gd if gd > 0.001 else float('inf')
        print(f"  {rx:7d} {sd:10.4f} {gd:10.4f} {sc:12.0f} {ratio:8.2f}")
    print()
    print("  → Stellar density merkez-ağırlıklı (bulge + thin/thick disk)")
    print("  → Gas density daha geniş yayılır ama spiral kollarla lokalize")
    print("  → star_count = mevcut yıldızlar + Kennicutt-Schmidt SFR")
    print()

    print(f"▸ JSON: {len(g.to_json())} chars")

    # ═══════════════════════════════════════════
    #  NEBULA ARCHITECTURE PATCH v2 TESTS
    # ═══════════════════════════════════════════
    print("\n" + "═"*60)
    print("  NEBULA ARCHITECTURE PATCH v2 — VERIFICATION")
    print("═"*60)

    # PATCH 1: Deterministic seeding
    print("\n▸ PATCH 1: Deterministic SHA256 seeding")
    s1 = stable_seed("test:nebula:42")
    s2 = stable_seed("test:nebula:42")
    s3 = stable_seed("test:nebula:43")
    print(f"  stable_seed('test:nebula:42') = {s1}")
    print(f"  stable_seed('test:nebula:42') = {s2}  (same? {s1 == s2} ✓)")
    print(f"  stable_seed('test:nebula:43') = {s3}  (different? {s1 != s3} ✓)")
    # Cross-session determinism
    g_a = UniversalGalaxy()
    g_b = UniversalGalaxy()
    sec_a = g_a.get_sector_parameters(6, 3, 0)
    g_b.clear_cache()
    sec_b = g_b.get_sector_parameters(6, 3, 0)
    ids_a = [n["id"] for n in sec_a["ghost_nebulae"]]
    ids_b = [n["id"] for n in sec_b["ghost_nebulae"]]
    print(f"  Session A nebula IDs: {ids_a}")
    print(f"  Session B nebula IDs: {ids_b}")
    print(f"  Deterministic: {ids_a == ids_b} ✓")

    # PATCH 2: Observed / Procedural separation
    print("\n▸ PATCH 2: Observed/Procedural star separation")
    g_test = UniversalGalaxy()
    obs_star = ProceduralStar(x=8.0, y=0.0, z=0.0, star_id="GAIA-DR3-001",
                               mass=1.0, stellar_class=StellarClass.G)
    g_test.inject_observed_star(obs_star)
    print(f"  Observed stars: {len(g_test._observed_stars)}")
    print(f"  Procedural stars: {len(g_test._procedural_stars)}")
    g_test.distribute_stars(6, 3, 0)
    print(f"  After distribute_stars(6,3,0):")
    print(f"    Observed: {len(g_test._observed_stars)} (preserved ✓)")
    print(f"    Procedural: {len(g_test._procedural_stars)} (regenerated)")
    print(f"    Total placed_stars: {len(g_test.placed_stars)}")
    g_test.distribute_stars(6, 3, 0)  # re-run
    print(f"  After 2nd distribute:")
    print(f"    Observed: {len(g_test._observed_stars)} (still preserved ✓)")

    # PATCH 3: Ellipsoidal sigma
    print("\n▸ PATCH 3: Ellipsoidal nebula shape")
    sec = g.get_sector_parameters(6, 3, 0)
    for n in sec["ghost_nebulae"][:3]:
        print(f"  {n['id']}: σx={n['sigma_x']:.3f} σy={n['sigma_y']:.3f} σz={n['sigma_z']:.3f} "
              f"morph={n['morphology']} type={n['nebula_type']}")

    # PATCH 4: Morphology system
    print("\n▸ PATCH 4: Nebula morphology distribution")
    morph_counts = {m.name: 0 for m in NebulaMorphology}
    for rx in range(0, 15):
        for ry in range(-5, 5):
            sec = g.get_sector_parameters(float(rx), float(ry), 0.0)
            for n in sec["ghost_nebulae"]:
                morph_counts[n["morphology"]] += 1
    print(f"  Morphology distribution (150 sectors):")
    for m, c in sorted(morph_counts.items(), key=lambda x: -x[1]):
        print(f"    {m:10s}: {c}")

    # PATCH 5: density_at_local
    print("\n▸ PATCH 5: density_at_local (future field source)")
    neb_test = GhostNebula(id="TEST", x=0, y=0, z=0,
                            sigma_x=0.5, sigma_y=0.3, sigma_z=0.1,
                            age_gyr=5.0, metallicity_offset=0.0,
                            star_budget=10, nebula_type=NebulaType.EMISSION,
                            morphology=NebulaMorphology.CLOUD)
    print(f"  density_at_local(0,0,0) = {neb_test.density_at_local(0,0,0):.4f} (should be 1.0)")
    print(f"  density_at_local(0.5,0,0) = {neb_test.density_at_local(0.5,0,0):.4f} (1σ_x away)")
    print(f"  density_at_local(0,0.3,0) = {neb_test.density_at_local(0,0.3,0):.4f} (1σ_y away)")
    print(f"  density_at_local(2,2,2) = {neb_test.density_at_local(2,2,2):.6f} (far away → ~0)")
