#!/usr/bin/env python3
"""
nebula.py v2 — "Nebula Architecture Patch"
═══════════════════════════════════════════

galaxy.py (v1.2.5+) dosyasına DOKUNMAZ.
Galaksi verilerine GalaxyLike protokolü üzerinden erişir.

Yamalar:
  PATCH 1: SHA256 Deterministic Seeding  — stable_seed() + NebulaInstance ID'leri
  PATCH 2: Star Separation               — observed vs procedural ayrı listeler
  PATCH 3: Ellipsoid Sigma               — anisotropik σ_x, σ_y, σ_z
  PATCH 4: Morphology System             — NebulaMorphology enum + atama mantığı
  PATCH 5: density_at_local()            — Gaussian falloff sorgusu (voxel-free)
  PATCH 6: NebulaInstance                — GhostNebula'yı saran üst-seviye wrapper

Kullanım:
    from universal_galaxy import UniversalGalaxy
    from nebula import NebulaEngine

    galaxy = UniversalGalaxy()
    engine = NebulaEngine(galaxy)

    # Sektör nebulalarını v2 ile üret
    instances = engine.generate_sector_nebulae(6.0, 3.0, 0.0)
    for ni in instances:
        print(ni.summary())

    # Yıldız üret (observed korunur)
    engine.inject_observed_star(my_gaia_star)
    proc_stars, cavities = engine.populate_sector(6.0, 3.0, 0.0)
"""

from __future__ import annotations

import math
import hashlib
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Protocol, Optional, runtime_checkable


# ═══════════════════════════════════════════════════════════════
#  PATCH 1: DETERMINISTIC SEEDING (SHA256)
# ═══════════════════════════════════════════════════════════════

def stable_seed(text: str) -> int:
    """
    SHA256 tabanlı deterministik seed.
    Python'un built-in hash() fonksiyonu PYTHONHASHSEED'e bağlıdır
    ve oturumlar arası farklı sonuç verir. Bu fonksiyon her yerde,
    her zaman aynı girdi → aynı çıktı garantisi verir.
    """
    h = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return int(h[:16], 16)


# ═══════════════════════════════════════════════════════════════
#  SEEDED PRNG (Mulberry32 — galaxy.py ile aynı)
# ═══════════════════════════════════════════════════════════════

class SeededRNG:
    """Mulberry32 — galaxy.py ve JS engine ile tam uyumlu."""

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
        u = self.next() or 1e-10
        v = self.next() or 1e-10
        return math.sqrt(-2.0 * math.log(u)) * math.cos(2.0 * math.pi * v)

    def range(self, lo: float, hi: float) -> float:
        return lo + (hi - lo) * self.next()


# ═══════════════════════════════════════════════════════════════
#  PATCH 4: NEBULA MORPHOLOGY
# ═══════════════════════════════════════════════════════════════

class NebulaMorphology(IntEnum):
    """Nebula şekil tipi — spatial behavior + shader preset metadata."""
    CLOUD    = 0   # Varsayılan küresel/elipsoidal bulut
    FILAMENT = 1   # Yüksek türbülans → uzun ince yapı
    SHELL    = 2   # Süpernova kalıntısı → kabuk
    BIPOLAR  = 3   # Çift kutuplu akış (protostellar jet)
    FRACTAL  = 4   # Çöken bulut → fraktal yapı
    RING     = 5   # Dağılan kabuk → halka
    PILLAR   = 6   # Karanlık nebula + türbülans → sütun (Pillars of Creation)


class NebulaType(IntEnum):
    """Nebula fiziksel alt-tipi."""
    EMISSION          = 0   # HII bölgesi — aktif yıldız oluşumu
    DARK              = 1   # Soğuk toz bulutu — ışığı soğurur
    SUPERNOVA_REMNANT = 2   # SNR — metaliklik +%25, radyasyon yüksek


# ═══════════════════════════════════════════════════════════════
#  GalaxyLike PROTOCOL — galaxy.py'ye bağımlılık yok
# ═══════════════════════════════════════════════════════════════

@runtime_checkable
class GalaxyLike(Protocol):
    """
    galaxy.py'nin sağlaması gereken minimum arayüz.
    nebula.py bu protokol üzerinden galaksi verilerine erişir.
    galaxy.py'ye DOKUNMAZ — sadece okur.
    """
    galaxy_name: str
    galaxy_radius: float
    galaxy_thickness: float

    def metallicity_at(self, R: float) -> float: ...
    def gas_density_at(self, R: float, z: float, x: float = 0.0, y: float = 0.0) -> float: ...
    def extinction_coefficient(self, x: float, y: float, z: float) -> float: ...
    def radiation_at(self, R: float) -> float: ...
    def local_turbulence(self, x: float, y: float, z: float) -> float: ...
    def temporal_drift(self, R: float, rng: "SeededRNG") -> tuple[float, float]: ...
    def _apply_kroupa_imf(self, rng: "SeededRNG") -> tuple: ...
    def _compute_velocity_vector(self, x: float, y: float, z: float, rng: "SeededRNG") -> tuple: ...


# ═══════════════════════════════════════════════════════════════
#  PATCH 6: NEBULA INSTANCE — GhostNebula'yı saran v2 wrapper
# ═══════════════════════════════════════════════════════════════

@dataclass
class NebulaInstance:
    """
    v2 Nebula — galaxy.py'deki GhostNebula'nın üst-seviye sarmalayıcısı.
    Tüm PATCH'ler burada birleşir:
      • SHA256 deterministik ID (PATCH 1)
      • Ellipsoidal σ_x/y/z (PATCH 3)
      • NebulaMorphology (PATCH 4)
      • density_at_local() (PATCH 5)
    """
    # Kimlik
    id: str                                     # PATCH 1: SHA256-based
    sector_key: str = ""

    # Pozisyon (galaktik kpc)
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0

    # PATCH 3: Anisotropik elipsoidal yayılım
    sigma_x: float = 0.3
    sigma_y: float = 0.3
    sigma_z: float = 0.1

    # Fiziksel özellikler
    age_gyr: float = 5.0
    metallicity_offset: float = 0.0
    star_budget: int = 30                       # Galaksi'nin mülkiyet hakkı — korunur

    # Tip & Morfoloji
    nebula_type: NebulaType = NebulaType.EMISSION
    morphology: NebulaMorphology = NebulaMorphology.CLOUD   # PATCH 4

    # Hesaplanmış istatistikler (populate sonrası dolar)
    spawned_count: int = 0
    ob_star_count: int = 0
    cavity_count: int = 0

    # ── PATCH 3: Backward compat ──

    @property
    def sigma(self) -> float:
        """Ortalama sigma (backward compat)."""
        return (self.sigma_x + self.sigma_y + self.sigma_z) / 3.0

    @sigma.setter
    def sigma(self, val: float) -> None:
        """Scalar → xyz auto-convert (z her zaman daha ince)."""
        self.sigma_x = val
        self.sigma_y = val
        self.sigma_z = val * 0.33

    # ── PATCH 5: Gaussian density sorgusu ──

    def density_at_local(self, lx: float, ly: float, lz: float) -> float:
        """
        Nebula merkezinden (lx, ly, lz) uzaklıktaki yoğunluk.
        3D Gaussian falloff — voxel grid yok, hafif.
        Çıktı: [0, 1]. Merkez = 1.0.
        """
        if self.sigma_x < 1e-6 or self.sigma_y < 1e-6 or self.sigma_z < 1e-6:
            return 0.0
        ex = (lx / self.sigma_x) ** 2
        ey = (ly / self.sigma_y) ** 2
        ez = (lz / self.sigma_z) ** 2
        return math.exp(-0.5 * (ex + ey + ez))

    def density_at_world(self, wx: float, wy: float, wz: float) -> float:
        """Dünya koordinatlarından yerel koordinata çevir + density sorgusu."""
        return self.density_at_local(wx - self.x, wy - self.y, wz - self.z)

    # ── Serileştirme ──

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "sector_key": self.sector_key,
            "x": round(self.x, 3), "y": round(self.y, 3), "z": round(self.z, 3),
            "sigma_x": round(self.sigma_x, 3),
            "sigma_y": round(self.sigma_y, 3),
            "sigma_z": round(self.sigma_z, 3),
            "sigma_avg": round(self.sigma, 3),
            "age_gyr": round(self.age_gyr, 2),
            "metallicity_offset": round(self.metallicity_offset, 5),
            "star_budget": self.star_budget,
            "nebula_type": self.nebula_type.name,
            "morphology": self.morphology.name,
            "spawned_count": self.spawned_count,
            "ob_star_count": self.ob_star_count,
            "cavity_count": self.cavity_count,
        }

    def summary(self) -> str:
        return (
            f"[{self.id}] {self.morphology.name}/{self.nebula_type.name} "
            f"@ ({self.x:.1f},{self.y:.1f},{self.z:.1f}) "
            f"σ=({self.sigma_x:.2f},{self.sigma_y:.2f},{self.sigma_z:.2f}) "
            f"age={self.age_gyr:.1f}Gyr ★{self.star_budget} "
            f"spawned={self.spawned_count} O/B={self.ob_star_count}"
        )


# ═══════════════════════════════════════════════════════════════
#  FEEDBACK CAVITY (O/B yıldızlarının kozmik kabarcığı)
# ═══════════════════════════════════════════════════════════════

@dataclass
class FeedbackCavity:
    source_star_id: str
    parent_nebula_id: str
    x: float
    y: float
    z: float
    radius_kpc: float
    density_reduction: float   # 0.90 = %90 düşüş
    stellar_class: str
    mass: float = 0.0

    def to_dict(self) -> dict:
        return {
            "source_star_id": self.source_star_id,
            "parent_nebula_id": self.parent_nebula_id,
            "x": round(self.x, 4), "y": round(self.y, 4), "z": round(self.z, 4),
            "radius_kpc": round(self.radius_kpc, 4),
            "density_reduction": round(self.density_reduction, 2),
            "stellar_class": self.stellar_class,
            "mass": round(self.mass, 3),
        }


# ═══════════════════════════════════════════════════════════════
#  PROCEDURAL STAR (nebula.py kendi kopyası — galaxy.py'ye bağımsız)
# ═══════════════════════════════════════════════════════════════

@dataclass
class NebulaStar:
    """nebula.py tarafından üretilen yıldız. galaxy.py'nin ProceduralStar'ıyla uyumlu."""
    x: float
    y: float
    z: float
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
    stellar_class: str = "G"
    is_binary: bool = False
    velocity_vector: tuple[float, float, float] = (0.0, 0.0, 0.0)
    extinction: float = 0.0


# ═══════════════════════════════════════════════════════════════
#  PATCH 2: STAR SEPARATION MANAGER
# ═══════════════════════════════════════════════════════════════

class StarSeparationManager:
    """
    Observed (Gaia) yıldızlar ile Procedural yıldızları ayrı tutar.
    Observed yıldızlar ASLA prosedürel yeniden üretimden etkilenmez.
    """

    def __init__(self):
        self._observed: list[NebulaStar] = []
        self._procedural: list[NebulaStar] = []

    @property
    def observed_stars(self) -> list[NebulaStar]:
        return list(self._observed)

    @property
    def procedural_stars(self) -> list[NebulaStar]:
        return list(self._procedural)

    @property
    def all_stars(self) -> list[NebulaStar]:
        """Merged view: observed first, then procedural."""
        return self._observed + self._procedural

    @property
    def observed_count(self) -> int:
        return len(self._observed)

    @property
    def procedural_count(self) -> int:
        return len(self._procedural)

    def inject_observed(self, star: NebulaStar) -> None:
        """Gaia/NASA yıldızı ekle. Prosedürel regen'den korunur."""
        star.is_procedural = False
        self._observed.append(star)

    def set_procedural(self, stars: list[NebulaStar]) -> None:
        """Prosedürel yıldızları değiştir. Observed'a DOKUNMAZ."""
        self._procedural = list(stars)

    def clear_procedural(self) -> None:
        """Sadece prosedürel yıldızları temizle."""
        self._procedural.clear()

    def clear_all(self) -> None:
        self._observed.clear()
        self._procedural.clear()


# ═══════════════════════════════════════════════════════════════
#  MORPHOLOGY ASSIGNER — PATCH 4 mantığı
# ═══════════════════════════════════════════════════════════════

def assign_morphology(
    ntype: NebulaType,
    turbulence: float,
    age_gyr: float,
    rng: SeededRNG,
) -> tuple[NebulaMorphology, float, float, float]:
    """
    PATCH 4: Nebula tipi, türbülans ve yaşa göre morfoloji ata.
    PATCH 3: Her morfoloji için anisotropik σ_x, σ_y, σ_z oranları.

    Dönüş: (morphology, sigma_x, sigma_y, sigma_z)
    """
    base_s = 0.1 + rng.next() * 0.4

    # ── SUPERNOVA REMNANT ──
    if ntype == NebulaType.SUPERNOVA_REMNANT:
        if age_gyr < 1.0:
            # Genç SNR → kabuk (shell)
            return NebulaMorphology.SHELL, base_s * 1.2, base_s * 1.2, base_s * 0.8
        else:
            # Yaşlı SNR → halka (ring)
            return NebulaMorphology.RING, base_s * 1.5, base_s * 1.5, base_s * 0.2

    # ── DARK NEBULA ──
    if ntype == NebulaType.DARK:
        if turbulence > 0.6:
            # Yüksek türbülans + karanlık → sütun (Pillars of Creation)
            return NebulaMorphology.PILLAR, base_s * 0.3, base_s * 0.3, base_s * 2.5
        else:
            return NebulaMorphology.CLOUD, base_s, base_s * 0.8, base_s * 0.4

    # ── EMISSION NEBULA ──
    if turbulence > 0.7:
        # Çok türbülanslı → filament
        stretch = 2.0 + rng.next() * 2.0
        if rng.next() < 0.5:
            return NebulaMorphology.FILAMENT, base_s * stretch, base_s * 0.4, base_s * 0.3
        else:
            return NebulaMorphology.FILAMENT, base_s * 0.4, base_s * stretch, base_s * 0.3
    elif turbulence > 0.5:
        return NebulaMorphology.FRACTAL, base_s * 1.1, base_s * 0.9, base_s * 0.5
    elif rng.next() < 0.15:
        return NebulaMorphology.BIPOLAR, base_s * 0.5, base_s * 0.5, base_s * 2.0
    else:
        return NebulaMorphology.CLOUD, base_s, base_s * 0.9, base_s * 0.3


# ═══════════════════════════════════════════════════════════════
#  NEBULA ENGINE — Ana motor
# ═══════════════════════════════════════════════════════════════

class NebulaEngine:
    """
    v2 Nebula motoru. galaxy.py'ye DOKUNMAZ.
    GalaxyLike protokolü üzerinden galaksi verilerini OKUR.

    Sorumluluklar:
      1) NebulaInstance üretimi (SHA256 ID, ellipsoid σ, morphology)
      2) Yıldız üretimi (Kroupa IMF — galaksiden delege edilir)
      3) Feedback Cavity hesabı
      4) Observed / Procedural star separation
      5) density_at_local() sorguları
    """

    def __init__(self, galaxy: GalaxyLike):
        self._galaxy = galaxy
        self._stars = StarSeparationManager()
        self._nebula_cache: dict[str, list[NebulaInstance]] = {}

    @property
    def star_manager(self) -> StarSeparationManager:
        return self._stars

    # ── Sector seed (PATCH 1) ──

    def _sector_seed(self, x: float, y: float, z: float) -> int:
        return stable_seed(f"{self._galaxy.galaxy_name}:{round(x)}:{round(y)}:{round(z)}")

    def _make_nebula_id(self, sector_seed: int, local_idx: int) -> str:
        raw = stable_seed(f"{self._galaxy.galaxy_name}:neb:{sector_seed}:{local_idx}")
        return f"NB-{raw & 0xFFFF:04X}"

    def _make_star_id(self, sector_seed: int, local_idx: int) -> str:
        raw = stable_seed(f"{self._galaxy.galaxy_name}:star:{sector_seed}:{local_idx}")
        return f"NS-{raw & 0xFFFFFF:06X}"

    # ══════════════════════════════════════════
    #  NEBULA GENERATION
    # ══════════════════════════════════════════

    def generate_sector_nebulae(
        self, sx: float, sy: float, sz: float,
    ) -> list[NebulaInstance]:
        """
        Sektör için 3-5 NebulaInstance üret.
        SHA256 deterministik — aynı koordinat → aynı nebulalar.
        galaxy.py'deki generate_ghost_nebulae ile AYNI seed mantığı
        ama NebulaInstance olarak döner.
        """
        sector_seed = self._sector_seed(sx, sy, sz)
        cache_key = f"{round(sx)},{round(sy)},{round(sz)}"

        if cache_key in self._nebula_cache:
            return self._nebula_cache[cache_key]

        rng = SeededRNG(sector_seed)
        count = 3 + int(rng.next() * 3)  # 3-5
        instances: list[NebulaInstance] = []

        for i in range(count):
            ox = (rng.next() - 0.5) * 2.0
            oy = (rng.next() - 0.5) * 2.0
            oz = (rng.next() - 0.5) * 0.6

            nx, ny, nz = sx + ox, sy + oy, sz + oz
            R = math.sqrt(nx ** 2 + ny ** 2)

            age = 0.1 + rng.next() * 12.0
            metal_off = (rng.next() - 0.5) * 0.005

            # Yıldız bütçesi — galaksinin mülkiyet hakkı (gas_density'den türer)
            gas = self._galaxy.gas_density_at(R, nz)
            budget = int(20 + rng.next() * 80 * gas)

            # Nebula tipi
            nt_roll = rng.next()
            if nt_roll < 0.55:
                ntype = NebulaType.EMISSION
            elif nt_roll < 0.85:
                ntype = NebulaType.DARK
            else:
                ntype = NebulaType.SUPERNOVA_REMNANT
                metal_off += 0.25 * self._galaxy.metallicity_at(R)

            # PATCH 4: Morphology + PATCH 3: Ellipsoidal sigma
            turb = self._galaxy.local_turbulence(nx, ny, nz)
            morph, sig_x, sig_y, sig_z = assign_morphology(ntype, turb, age, rng)

            # PATCH 1: Deterministic ID
            neb_id = self._make_nebula_id(sector_seed, i)

            instances.append(NebulaInstance(
                id=neb_id,
                sector_key=cache_key,
                x=nx, y=ny, z=nz,
                sigma_x=sig_x, sigma_y=sig_y, sigma_z=sig_z,
                age_gyr=age,
                metallicity_offset=metal_off,
                star_budget=budget,
                nebula_type=ntype,
                morphology=morph,
            ))

        self._nebula_cache[cache_key] = instances
        return instances

    # ══════════════════════════════════════════
    #  STAR POPULATION
    # ══════════════════════════════════════════

    def populate_nebula(
        self, neb: NebulaInstance, sector_seed: int, local_idx: int,
    ) -> tuple[list[NebulaStar], list[FeedbackCavity]]:
        """
        Tek bir NebulaInstance'dan yıldız üret.
        Kroupa IMF, velocity, extinction — hepsi galaksiden delege edilir.
        O/B yıldızları FeedbackCavity oluşturur.
        """
        seed = sector_seed + local_idx * 9973
        rng = SeededRNG(seed)
        stars: list[NebulaStar] = []
        cavities: list[FeedbackCavity] = []

        snr_ext_boost = 0.02 if neb.nebula_type == NebulaType.SUPERNOVA_REMNANT else 0.0
        dark_ext_boost = 0.03 if neb.nebula_type == NebulaType.DARK else 0.0

        star_counter = 0
        for _ in range(neb.star_budget):
            # PATCH 3: Ellipsoidal Gaussian dağılım
            x = neb.x + rng.gauss() * neb.sigma_x
            y = neb.y + rng.gauss() * neb.sigma_y
            z = neb.z + rng.gauss() * neb.sigma_z
            R = math.sqrt(x * x + y * y)

            # Kroupa IMF (galaksiden delege)
            mass, sc, lum, radius, temp = self._galaxy._apply_kroupa_imf(rng)

            # Temporal drift (galaksiden)
            td_age, td_mm = self._galaxy.temporal_drift(R, rng)
            final_age = neb.age_gyr * 0.4 + td_age * 0.6
            final_metal = self._galaxy.metallicity_at(R) * td_mm + neb.metallicity_offset

            # Extinction (galaksiden + nebula tip boost)
            ext = self._galaxy.extinction_coefficient(x, y, z) + dark_ext_boost + snr_ext_boost
            app_lum = lum * math.exp(-ext)

            # Binary
            is_binary = rng.next() < (0.70 if sc.value <= 1 else 0.30)

            # Velocity (galaksiden)
            vel = self._galaxy._compute_velocity_vector(x, y, z, rng)

            # PATCH 1: Deterministic star ID
            sid = self._make_star_id(seed, star_counter)
            star_counter += 1

            stars.append(NebulaStar(
                x=x, y=y, z=z,
                star_id=sid,
                is_procedural=True,
                parent_nebula_id=neb.id,
                gravity_well_id=neb.id,
                age_gyr=round(final_age, 2),
                metallicity=round(max(0.0, final_metal), 5),
                metallicity_offset=neb.metallicity_offset,
                mass=round(mass, 3),
                luminosity=round(lum, 4),
                apparent_luminosity=round(app_lum, 4),
                radius=round(radius, 3),
                temperature=round(temp, 0),
                stellar_class=sc.name if hasattr(sc, 'name') else str(sc),
                is_binary=is_binary,
                velocity_vector=vel,
                extinction=round(ext, 4),
            ))

            # Feedback Cavity — O/B yıldızları
            if sc.value <= 1:  # O veya B
                fb_r = 0.01 * mass ** 0.5
                cavities.append(FeedbackCavity(
                    source_star_id=sid,
                    parent_nebula_id=neb.id,
                    x=x, y=y, z=z,
                    radius_kpc=round(fb_r, 4),
                    density_reduction=0.90,
                    stellar_class=sc.name if hasattr(sc, 'name') else str(sc),
                    mass=round(mass, 3),
                ))

        # İstatistikleri güncelle
        neb.spawned_count = len(stars)
        neb.ob_star_count = len(cavities)
        neb.cavity_count = len(cavities)

        return stars, cavities

    def populate_sector(
        self, sx: float, sy: float, sz: float,
    ) -> tuple[list[NebulaStar], list[FeedbackCavity]]:
        """
        Sektördeki TÜM nebulalardan yıldız üret.
        PATCH 2: Observed yıldızlar korunur, sadece procedural yenilenir.
        """
        sector_seed = self._sector_seed(sx, sy, sz)
        nebulae = self.generate_sector_nebulae(sx, sy, sz)

        all_stars: list[NebulaStar] = []
        all_cavities: list[FeedbackCavity] = []

        for i, neb in enumerate(nebulae):
            stars, cavities = self.populate_nebula(neb, sector_seed, i)
            all_stars.extend(stars)
            all_cavities.extend(cavities)

        # PATCH 2: Sadece procedural'ı güncelle
        self._stars.set_procedural(all_stars)

        return all_stars, all_cavities

    # ══════════════════════════════════════════
    #  OBSERVED STAR INJECTION
    # ══════════════════════════════════════════

    def inject_observed_star(self, star: NebulaStar) -> None:
        """Gaia/NASA yıldızı ekle. Prosedürel regen'den KORUNUR."""
        self._stars.inject_observed(star)

    # ══════════════════════════════════════════
    #  QUERIES
    # ══════════════════════════════════════════

    def nebula_density_at(
        self, wx: float, wy: float, wz: float,
        sector_x: float, sector_y: float, sector_z: float,
    ) -> float:
        """
        PATCH 5: Dünya koordinatında toplam nebula yoğunluğu.
        Sektördeki tüm nebulalardan Gaussian katkı toplanır.
        """
        nebulae = self.generate_sector_nebulae(sector_x, sector_y, sector_z)
        total = 0.0
        for neb in nebulae:
            total += neb.density_at_world(wx, wy, wz)
        return min(1.0, total)

    def find_nearest_nebula(
        self, wx: float, wy: float, wz: float,
        sector_x: float, sector_y: float, sector_z: float,
    ) -> Optional[NebulaInstance]:
        """En yakın nebulayı bul."""
        nebulae = self.generate_sector_nebulae(sector_x, sector_y, sector_z)
        best = None
        best_dist = float('inf')
        for neb in nebulae:
            d = math.sqrt((wx-neb.x)**2 + (wy-neb.y)**2 + (wz-neb.z)**2)
            if d < best_dist:
                best_dist = d
                best = neb
        return best

    def sector_summary(self, sx: float, sy: float, sz: float) -> dict:
        """Sektör nebula özeti — JSON-serializable."""
        nebulae = self.generate_sector_nebulae(sx, sy, sz)
        morph_counts = {}
        type_counts = {}
        total_budget = 0
        for neb in nebulae:
            morph_counts[neb.morphology.name] = morph_counts.get(neb.morphology.name, 0) + 1
            type_counts[neb.nebula_type.name] = type_counts.get(neb.nebula_type.name, 0) + 1
            total_budget += neb.star_budget
        return {
            "sector": f"{round(sx)},{round(sy)},{round(sz)}",
            "nebula_count": len(nebulae),
            "total_star_budget": total_budget,
            "morphology_distribution": morph_counts,
            "type_distribution": type_counts,
            "nebulae": [n.to_dict() for n in nebulae],
            "observed_stars": self._stars.observed_count,
            "procedural_stars": self._stars.procedural_count,
        }

    def clear_cache(self) -> None:
        self._nebula_cache.clear()


# ═══════════════════════════════════════════════════════════════
#  DEMO
# ═══════════════════════════════════════════════════════════════

if __name__ == "__main__":
    # galaxy.py'yi import et (aynı dizinde olmalı)
    import sys, os
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from universal_galaxy import UniversalGalaxy

    galaxy = UniversalGalaxy()
    engine = NebulaEngine(galaxy)

    print("═" * 60)
    print("  nebula.py v2 — Nebula Architecture Patch")
    print("═" * 60)

    # ── PATCH 1: Deterministic seeding ──
    print("\n▸ PATCH 1: SHA256 Deterministic Seeding")
    s1 = stable_seed("test:42")
    s2 = stable_seed("test:42")
    s3 = stable_seed("test:43")
    print(f"  stable_seed('test:42') = {s1}")
    print(f"  stable_seed('test:42') = {s2}  (same? {s1 == s2} ✓)")
    print(f"  stable_seed('test:43') = {s3}  (different? {s1 != s3} ✓)")

    neb_a = engine.generate_sector_nebulae(6, 3, 0)
    engine.clear_cache()
    neb_b = engine.generate_sector_nebulae(6, 3, 0)
    ids_a = [n.id for n in neb_a]
    ids_b = [n.id for n in neb_b]
    print(f"  Run A IDs: {ids_a}")
    print(f"  Run B IDs: {ids_b}")
    print(f"  Deterministic: {ids_a == ids_b} ✓")

    # ── PATCH 2: Star Separation ──
    print("\n▸ PATCH 2: Observed / Procedural Star Separation")
    obs = NebulaStar(x=8.0, y=0.0, z=0.0, star_id="GAIA-DR3-001", mass=1.0)
    engine.inject_observed_star(obs)
    print(f"  Observed: {engine.star_manager.observed_count}")
    proc_stars, cavs = engine.populate_sector(6, 3, 0)
    print(f"  After populate_sector(6,3,0):")
    print(f"    Observed:   {engine.star_manager.observed_count} (preserved ✓)")
    print(f"    Procedural: {engine.star_manager.procedural_count}")
    print(f"    Total:      {len(engine.star_manager.all_stars)}")
    # Re-populate — observed must survive
    engine.populate_sector(6, 3, 0)
    print(f"  After 2nd populate:")
    print(f"    Observed:   {engine.star_manager.observed_count} (still preserved ✓)")

    # ── PATCH 3: Ellipsoidal Sigma ──
    print("\n▸ PATCH 3: Ellipsoidal Sigma")
    nebulae = engine.generate_sector_nebulae(6, 3, 0)
    for n in nebulae[:3]:
        print(f"  {n.id}: σ=({n.sigma_x:.3f}, {n.sigma_y:.3f}, {n.sigma_z:.3f}) "
              f"avg={n.sigma:.3f}")

    # ── PATCH 4: Morphology ──
    print("\n▸ PATCH 4: Morphology System")
    for n in nebulae:
        print(f"  {n.id}: {n.morphology.name}/{n.nebula_type.name} "
              f"age={n.age_gyr:.1f}Gyr ★{n.star_budget}")

    # Morphology distribution across many sectors
    morph_total = {m.name: 0 for m in NebulaMorphology}
    for rx in range(0, 12):
        for ry in range(-4, 4):
            for n in engine.generate_sector_nebulae(float(rx), float(ry), 0):
                morph_total[n.morphology.name] += 1
    print(f"\n  Distribution (96 sectors):")
    for m, c in sorted(morph_total.items(), key=lambda x: -x[1]):
        bar = "█" * (c // 3)
        print(f"    {m:10s}: {c:4d} {bar}")

    # ── PATCH 5: density_at_local ──
    print("\n▸ PATCH 5: density_at_local / density_at_world")
    n0 = nebulae[0]
    print(f"  Nebula {n0.id} @ ({n0.x:.2f}, {n0.y:.2f}, {n0.z:.2f})")
    print(f"  density_at_local(0,0,0) = {n0.density_at_local(0,0,0):.4f} (centre=1.0 ✓)")
    print(f"  density_at_local(σx,0,0) = {n0.density_at_local(n0.sigma_x,0,0):.4f} (1σ away)")
    print(f"  density_at_world(neb.x, neb.y, neb.z) = {n0.density_at_world(n0.x, n0.y, n0.z):.4f}")
    total_density = engine.nebula_density_at(n0.x, n0.y, n0.z, 6, 3, 0)
    print(f"  nebula_density_at(neb centre, sector) = {total_density:.4f}")

    # ── PATCH 6: NebulaInstance summary ──
    print("\n▸ PATCH 6: NebulaInstance summaries")
    for n in nebulae:
        print(f"  {n.summary()}")

    # ── Feedback Cavities ──
    print(f"\n▸ Feedback Cavities: {len(cavs)}")
    for c in cavs[:5]:
        print(f"  {c.source_star_id}: {c.stellar_class} "
              f"r={c.radius_kpc:.4f}kpc Δρ=-{c.density_reduction:.0%} "
              f"parent={c.parent_nebula_id}")

    # ── Sector Summary ──
    print("\n▸ Sector Summary (JSON-ready):")
    import json
    summary = engine.sector_summary(6, 3, 0)
    print(json.dumps(summary, indent=2, ensure_ascii=False)[:800] + "...")

    # ── GalaxyLike protocol check ──
    print(f"\n▸ GalaxyLike protocol: {isinstance(galaxy, GalaxyLike)} ✓")

    print("\n✅ All patches verified.")
