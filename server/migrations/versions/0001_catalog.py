"""Initial PostgreSQL catalog, frozen DDL (not live ORM metadata)."""
from alembic import op
revision = '0001'
down_revision = None
branch_labels = None
depends_on = None

def upgrade():
    op.execute('\nCREATE TABLE catalog_state (\n\tid SERIAL NOT NULL, \n\tgeneration VARCHAR NOT NULL, \n\tversion BIGINT NOT NULL, \n\tPRIMARY KEY (id)\n)\n\n')
    op.execute('\nCREATE TABLE categories (\n\tid VARCHAR NOT NULL, \n\tparent_id VARCHAR, \n\tname TEXT NOT NULL, \n\tlevel INTEGER NOT NULL, \n\tsort_order INTEGER NOT NULL, \n\tsource_url TEXT NOT NULL, \n\tversion BIGINT NOT NULL, \n\tPRIMARY KEY (id), \n\tFOREIGN KEY(parent_id) REFERENCES categories (id)\n)\n\n')
    op.execute('CREATE INDEX ix_categories_parent_id ON categories (parent_id)')
    op.execute('\nCREATE TABLE product_changes (\n\tversion BIGINT NOT NULL, \n\tkind VARCHAR NOT NULL, \n\tentity_id VARCHAR NOT NULL, \n\tpayload JSONB NOT NULL, \n\tPRIMARY KEY (version)\n)\n\n')
    op.execute('CREATE INDEX ix_change_entity_version ON product_changes (kind, entity_id, version)')
    op.execute('\nCREATE TABLE promotions (\n\tid VARCHAR NOT NULL, \n\tdata JSONB NOT NULL, \n\tversion BIGINT NOT NULL, \n\tPRIMARY KEY (id)\n)\n\n')
    op.execute('\nCREATE TABLE special_collections (\n\tid VARCHAR NOT NULL, \n\tdata JSONB NOT NULL, \n\tversion BIGINT NOT NULL, \n\tPRIMARY KEY (id)\n)\n\n')
    op.execute('\nCREATE TABLE sync_runs (\n\tid VARCHAR NOT NULL, \n\tstarted_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tfinished_at TIMESTAMP WITH TIME ZONE, \n\tstatus VARCHAR NOT NULL, \n\tstats JSONB NOT NULL, \n\tPRIMARY KEY (id)\n)\n\n')
    op.execute('\nCREATE TABLE products (\n\tid VARCHAR NOT NULL, \n\tsource_product_id VARCHAR NOT NULL, \n\tsku VARCHAR, \n\tbarcode VARCHAR, \n\tname TEXT NOT NULL, \n\tbrand TEXT, \n\tquantity TEXT, \n\tprice NUMERIC(12, 2), \n\told_price NUMERIC(12, 2), \n\tpromo_price NUMERIC(12, 2), \n\tdiscount_percent NUMERIC(6, 2), \n\tpromotion_state VARCHAR NOT NULL, \n\tpromotion_start VARCHAR, \n\tpromotion_end VARCHAR, \n\tcategory_id VARCHAR, \n\tproduct_url TEXT NOT NULL, \n\tthumbnail_url TEXT, \n\tsource_image_url TEXT, \n\tfull_image_url TEXT, \n\tin_stock BOOLEAN, \n\tpossibly_inactive BOOLEAN NOT NULL, \n\tinactive BOOLEAN NOT NULL, \n\tmissing_count INTEGER NOT NULL, \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tupdated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tversion BIGINT NOT NULL, \n\tPRIMARY KEY (id), \n\tUNIQUE (source_product_id), \n\tUNIQUE (sku), \n\tUNIQUE (barcode), \n\tFOREIGN KEY(category_id) REFERENCES categories (id), \n\tUNIQUE (product_url)\n)\n\n')
    op.execute('CREATE INDEX ix_products_updated_at ON products (updated_at)')
    op.execute('CREATE INDEX ix_products_category_id ON products (category_id)')
    op.execute('\nCREATE TABLE pending_identifiers (\n\tid VARCHAR NOT NULL, \n\tsku VARCHAR, \n\tbarcode VARCHAR, \n\tstatus VARCHAR NOT NULL, \n\tproduct_id VARCHAR, \n\tdata JSONB NOT NULL, \n\tversion BIGINT NOT NULL, \n\tPRIMARY KEY (id), \n\tFOREIGN KEY(product_id) REFERENCES products (id)\n)\n\n')
    op.execute('CREATE INDEX ix_pending_identifiers_barcode ON pending_identifiers (barcode)')
    op.execute('CREATE INDEX ix_pending_identifiers_sku ON pending_identifiers (sku)')
    op.execute('\nCREATE TABLE product_promotions (\n\tproduct_id VARCHAR NOT NULL, \n\tpromotion_id VARCHAR NOT NULL, \n\tPRIMARY KEY (product_id, promotion_id), \n\tFOREIGN KEY(product_id) REFERENCES products (id), \n\tFOREIGN KEY(promotion_id) REFERENCES promotions (id)\n)\n\n')
    op.execute('\nCREATE TABLE special_collection_products (\n\tcollection_id VARCHAR NOT NULL, \n\tproduct_id VARCHAR NOT NULL, \n\tPRIMARY KEY (collection_id, product_id), \n\tFOREIGN KEY(collection_id) REFERENCES special_collections (id), \n\tFOREIGN KEY(product_id) REFERENCES products (id)\n)\n\n')
    op.execute("INSERT INTO catalog_state(id,generation,version) VALUES (1,gen_random_uuid()::text,0)")

def downgrade():
    op.drop_table('special_collection_products')
    op.drop_table('product_promotions')
    op.drop_table('pending_identifiers')
    op.drop_table('products')
    op.drop_table('sync_runs')
    op.drop_table('special_collections')
    op.drop_table('promotions')
    op.drop_table('product_changes')
    op.drop_table('categories')
    op.drop_table('catalog_state')
