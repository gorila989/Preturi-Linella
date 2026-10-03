from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4
from sqlalchemy import BigInteger, Boolean, DateTime, ForeignKey, Integer, Numeric, String, Text, Index
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def now():
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class CatalogState(Base):
    __tablename__ = 'catalog_state'
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    generation: Mapped[str] = mapped_column(String, default=lambda: str(uuid4()))
    version: Mapped[int] = mapped_column(BigInteger, default=0)


class Category(Base):
    __tablename__ = 'categories'
    id: Mapped[str] = mapped_column(String, primary_key=True)
    parent_id: Mapped[str | None] = mapped_column(ForeignKey('categories.id'), index=True)
    name: Mapped[str] = mapped_column(Text)
    level: Mapped[int] = mapped_column(Integer)
    sort_order: Mapped[int] = mapped_column(Integer)
    source_url: Mapped[str] = mapped_column(Text)
    version: Mapped[int] = mapped_column(BigInteger, default=0)


class Product(Base):
    __tablename__ = 'products'
    id: Mapped[str] = mapped_column(String, primary_key=True)
    source_product_id: Mapped[str] = mapped_column(String, unique=True)
    sku: Mapped[str | None] = mapped_column(String, unique=True)
    barcode: Mapped[str | None] = mapped_column(String, unique=True)
    name: Mapped[str] = mapped_column(Text)
    brand: Mapped[str | None] = mapped_column(Text)
    quantity: Mapped[str | None] = mapped_column(Text)
    price: Mapped[Decimal | None] = mapped_column(Numeric(12, 2))
    old_price: Mapped[Decimal | None] = mapped_column(Numeric(12, 2))
    promo_price: Mapped[Decimal | None] = mapped_column(Numeric(12, 2))
    discount_percent: Mapped[Decimal | None] = mapped_column(Numeric(6, 2))
    promotion_state: Mapped[str] = mapped_column(String, default='none')
    promotion_start: Mapped[str | None] = mapped_column(String)
    promotion_end: Mapped[str | None] = mapped_column(String)
    category_id: Mapped[str | None] = mapped_column(ForeignKey('categories.id'), index=True)
    product_url: Mapped[str] = mapped_column(Text, unique=True)
    thumbnail_url: Mapped[str | None] = mapped_column(Text)
    source_image_url: Mapped[str | None] = mapped_column(Text)
    full_image_url: Mapped[str | None] = mapped_column(Text)
    in_stock: Mapped[bool | None] = mapped_column(Boolean)
    possibly_inactive: Mapped[bool] = mapped_column(Boolean, default=False)
    inactive: Mapped[bool] = mapped_column(Boolean, default=False)
    missing_count: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, index=True)
    version: Mapped[int] = mapped_column(BigInteger, default=0)


class Promotion(Base):
    __tablename__ = 'promotions'
    id: Mapped[str] = mapped_column(String, primary_key=True)
    data: Mapped[dict] = mapped_column(JSONB)
    version: Mapped[int] = mapped_column(BigInteger, default=0)


class ProductPromotion(Base):
    __tablename__ = 'product_promotions'
    product_id: Mapped[str] = mapped_column(ForeignKey('products.id'), primary_key=True)
    promotion_id: Mapped[str] = mapped_column(ForeignKey('promotions.id'), primary_key=True)


class SpecialCollection(Base):
    __tablename__ = 'special_collections'
    id: Mapped[str] = mapped_column(String, primary_key=True)
    data: Mapped[dict] = mapped_column(JSONB)
    version: Mapped[int] = mapped_column(BigInteger, default=0)


class SpecialCollectionProduct(Base):
    __tablename__ = 'special_collection_products'
    collection_id: Mapped[str] = mapped_column(ForeignKey('special_collections.id'), primary_key=True)
    product_id: Mapped[str] = mapped_column(ForeignKey('products.id'), primary_key=True)


class ProductChange(Base):
    __tablename__ = 'product_changes'
    # A transactional counter protected by catalog_state FOR UPDATE, NOT a sequence:
    # publication order is commit order; a rolled back writer cannot cause a gap.
    version: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=False)
    kind: Mapped[str] = mapped_column(String)
    entity_id: Mapped[str] = mapped_column(String)
    payload: Mapped[dict] = mapped_column(JSONB)
    __table_args__ = (Index('ix_change_entity_version', 'kind', 'entity_id', 'version'),)


class SyncRun(Base):
    __tablename__ = 'sync_runs'
    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid4()))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    status: Mapped[str] = mapped_column(String, default='running')
    stats: Mapped[dict] = mapped_column(JSONB, default=dict)


class PendingProductIdentifier(Base):
    __tablename__ = 'pending_identifiers'
    id: Mapped[str] = mapped_column(String, primary_key=True)
    sku: Mapped[str | None] = mapped_column(String, index=True)
    barcode: Mapped[str | None] = mapped_column(String, index=True)
    status: Mapped[str] = mapped_column(String)
    product_id: Mapped[str | None] = mapped_column(ForeignKey('products.id'))
    data: Mapped[dict] = mapped_column(JSONB)
    version: Mapped[int] = mapped_column(BigInteger, default=0)
