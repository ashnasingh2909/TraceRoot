import unittest
from datetime import date

from app import create_app, db
from app.models import Batch, Product, Farm, User, Role, ProcessingUnit, Inspection, InspectionParameter, Shipment, AuditLog


class SQLiteSplitBatchTest(unittest.TestCase):
    def setUp(self):
        class TestConfig:
            SECRET_KEY = 'test-secret'
            SQLALCHEMY_DATABASE_URI = 'sqlite:///'
            SQLALCHEMY_TRACK_MODIFICATIONS = False

        self.app = create_app(TestConfig)
        self.app_context = self.app.app_context()
        self.app_context.push()
        db.session.remove()
        db.drop_all()
        db.create_all()

        farmer_role = Role(role_id=2, role_name='FARMER')
        processor_role = Role(role_id=3, role_name='PROCESSOR')
        inspector_role = Role(role_id=4, role_name='INSPECTOR')
        retailer_role = Role(role_id=5, role_name='RETAILER')
        fso_role = Role(role_id=6, role_name='FOOD_SAFETY_OFFICER')
        db.session.add_all([farmer_role, processor_role, inspector_role, retailer_role, fso_role])
        db.session.commit()

        farmer = User(username='farmer_test', email='farmer@example.com', full_name='Farmer Test', role_id=farmer_role.role_id, is_active=True)
        farmer.set_password('password123')
        processor = User(username='processor_test', email='processor@example.com', full_name='Processor Test', role_id=processor_role.role_id, is_active=True)
        processor.set_password('password123')
        inspector = User(username='inspector_test', email='inspector@example.com', full_name='Inspector Test', role_id=inspector_role.role_id, is_active=True)
        inspector.set_password('password123')
        retailer = User(username='retailer_test', email='retailer@example.com', full_name='Retailer Test', role_id=retailer_role.role_id, is_active=True)
        retailer.set_password('password123')
        fso = User(username='fso_test', email='fso@example.com', full_name='Safety Officer', role_id=fso_role.role_id, is_active=True)
        fso.set_password('password123')
        db.session.add_all([farmer, processor, inspector, retailer, fso])
        db.session.commit()
        self.farmer = farmer
        self.processor = processor
        self.inspector = inspector
        self.retailer = retailer
        self.fso = fso

        farm = Farm(farm_code='FARM-01', farm_name='Test Farm', owner_id=farmer.user_id, district='x', state='y', area_acres=10, organic_certified=True)
        product = Product(product_name='Turmeric', category='SPICE', shelf_life_days=30)
        unit = ProcessingUnit(unit_code='PU-01', unit_name='Test Unit', location='City', fssai_license_no='FSSAI-0001', manager_id=processor.user_id)
        db.session.add_all([farm, product, unit])
        db.session.commit()
        self.farm = farm
        self.product = product
        self.unit = unit

        self.batch = Batch(
            batch_code='BATCH-TEST-001',
            product_id=product.product_id,
            batch_type='HARVEST',
            farm_id=farm.farm_id,
            processing_unit_id=unit.unit_id,
            initial_quantity_kg=100,
            quantity_kg=100,
            harvest_date=date(2025, 1, 1),
            expiry_date=date(2025, 2, 1),
            status='ACTIVE',
            stage='HARVESTED',
            created_by=farmer.user_id,
        )
        db.session.add(self.batch)
        db.session.commit()

    def tearDown(self):
        db.session.remove()
        self.app_context.pop()

    def test_sqlite_split_batch_helper_updates_parent_and_children(self):
        from app.main.routes import _split_batch_transaction

        self.batch.processing_unit_id = None
        result = _split_batch_transaction(
            self.batch,
            [{'qty': 60.0}, {'qty': 40.0}],
            self.processor.user_id,
            self.unit.unit_id,
        )

        self.assertEqual(result['created_children'], 2)
        self.assertEqual(self.batch.processing_unit_id, self.unit.unit_id)
        self.assertEqual(float(self.batch.quantity_kg), 0.0)
        self.assertEqual(self.batch.status, 'CONSUMED')
        self.assertEqual(Batch.query.filter_by(batch_code='BATCH-TEST-001-S1').count(), 1)
        self.assertEqual(Batch.query.filter_by(batch_code='BATCH-TEST-001-S2').count(), 1)

    def test_new_farmer_batch_appears_in_processor_list(self):
        from flask_login import login_user
        from app.main.routes import create_batch, processor_batches

        with self.app.test_request_context('/farmer/batch/create', method='POST', data={
                'batch_code': 'BATCH-FORM-001',
                'farm_id': str(self.farm.farm_id),
                'product_id': str(self.product.product_id),
                'quantity_kg': '25',
                'harvest_date': '2025-03-01',
        }):
            login_user(self.farmer)
            create_response = create_batch()
        self.assertEqual(create_response.status_code, 302)

        with self.app.test_request_context('/processor/batches'):
            login_user(self.processor)
            response = processor_batches()

        self.assertIn('BATCH-FORM-001', response)

    def test_clean_startup_does_not_seed_sample_batches(self):
        from app import seed_default_data

        db.session.remove()
        db.drop_all()
        db.create_all()
        seed_default_data()

        self.assertEqual(Batch.query.count(), 0)

    def test_inspection_saves_selected_test_without_parameter_rows(self):
        from flask_login import login_user
        from app.main.routes import create_inspection

        with self.app.test_request_context(
            f'/inspector/inspection/create/{self.batch.batch_id}',
            method='POST',
            data={
                'test_type': 'Moisture content',
                'result': 'PASS',
                'remarks': 'Within specification',
            },
        ):
            login_user(self.inspector)
            response = create_inspection(self.batch.batch_id)

        self.assertEqual(response.status_code, 302)
        inspection = Inspection.query.one()
        self.assertEqual(inspection.test_type, 'Moisture content')
        self.assertEqual(inspection.result, 'PASS')
        self.assertEqual(InspectionParameter.query.count(), 0)

    def test_retailer_dashboard_lists_batches_cleared_by_inspection(self):
        from flask_login import login_user
        from app.main.routes import create_inspection, dashboard

        uninspected_batch = Batch(
            batch_code='BATCH-NO-PASS',
            product_id=self.product.product_id,
            batch_type='HARVEST',
            farm_id=self.farm.farm_id,
            processing_unit_id=self.unit.unit_id,
            initial_quantity_kg=20,
            quantity_kg=20,
            harvest_date=self.batch.harvest_date,
            expiry_date=self.batch.expiry_date,
            status='ACTIVE',
            stage='HARVESTED',
            created_by=self.farmer.user_id,
        )
        db.session.add(uninspected_batch)
        db.session.commit()

        with self.app.test_request_context(
            f'/inspector/inspection/create/{self.batch.batch_id}',
            method='POST',
            data={
                'test_type': 'Visual examination',
                'result': 'PASS',
                'remarks': 'Approved for distribution',
            },
        ):
            login_user(self.inspector)
            inspection_response = create_inspection(self.batch.batch_id)

        self.assertEqual(inspection_response.status_code, 302)

        with self.app.test_request_context('/dashboard'):
            login_user(self.retailer)
            page = dashboard()

        self.assertIn('Approved batches available', page)
        self.assertIn('BATCH-TEST-001', page)
        self.assertIn('Turmeric', page)
        self.assertNotIn('BATCH-NO-PASS', page)
        self.assertEqual(Shipment.query.count(), 0)

    def test_inspector_view_details_opens_the_matching_batch_inspection(self):
        from flask_login import login_user
        from app.main.routes import dashboard, view_batch

        inspection = Inspection(
            batch_id=self.batch.batch_id,
            inspector_id=self.inspector.user_id,
            test_type='Moisture content',
            result='PASS',
            remarks='Within specification',
        )
        db.session.add(inspection)
        db.session.commit()

        with self.app.test_request_context('/dashboard'):
            login_user(self.inspector)
            dashboard_html = dashboard()

        with self.app.test_request_context(f'/batch/{self.batch.batch_id}'):
            login_user(self.inspector)
            batch_html = view_batch(self.batch.batch_id)

        detail_url = f'/batch/{self.batch.batch_id}#inspection-{inspection.inspection_id}'
        self.assertIn(f'href="{detail_url}"', dashboard_html)
        self.assertIn(f'id="inspection-{inspection.inspection_id}"', batch_html)
        self.assertIn('Moisture content', batch_html)
        self.assertIn('Within specification', batch_html)

    def test_failed_inspection_quarantines_batch_farm_and_cancels_shipments(self):
        from flask import get_flashed_messages
        from flask_login import login_user
        from app.main.routes import create_inspection

        shipment = Shipment(
            batch_id=self.batch.batch_id,
            retailer_id=self.retailer.user_id,
            quantity_kg=10,
            shipped_date=date.today(),
            status='PENDING',
            created_by=self.processor.user_id,
        )
        db.session.add(shipment)
        db.session.commit()

        with self.app.test_request_context(
            f'/inspector/inspection/create/{self.batch.batch_id}',
            method='POST',
            data={
                'test_type': 'Microbiological safety',
                'result': 'FAIL',
                'remarks': 'Unsafe sample',
            },
        ):
            login_user(self.inspector)
            response = create_inspection(self.batch.batch_id)
            messages = get_flashed_messages(with_categories=True)

        self.assertTrue(hasattr(response, 'status_code'), messages)
        self.assertEqual(response.status_code, 302)
        self.assertEqual(self.batch.status, 'QUARANTINED')
        self.assertEqual(self.farm.status, 'QUARANTINED')
        self.assertEqual(shipment.status, 'CANCELLED')
        self.assertEqual(AuditLog.query.filter_by(table_name='batches', action='QUARANTINE').count(), 1)

    def test_existing_failed_inspection_is_reconciled_to_quarantine(self):
        from app import reconcile_failed_inspections

        db.session.add(Inspection(
            batch_id=self.batch.batch_id,
            inspector_id=self.inspector.user_id,
            test_type='Visual examination',
            result='FAIL',
            remarks='Legacy failed inspection',
        ))
        db.session.commit()

        reconcile_failed_inspections()

        self.assertEqual(self.batch.status, 'QUARANTINED')
        self.assertEqual(self.farm.status, 'QUARANTINED')

    def test_farmer_cannot_create_batch_from_quarantined_farm(self):
        from flask import get_flashed_messages
        from flask_login import login_user
        from app.main.routes import create_batch

        self.farm.status = 'QUARANTINED'
        db.session.commit()
        initial_count = Batch.query.count()

        with self.app.test_request_context('/farmer/batch/create', method='POST', data={
            'batch_code': 'BATCH-BLOCKED-001',
            'farm_id': str(self.farm.farm_id),
            'product_id': str(self.product.product_id),
            'quantity_kg': '12',
            'harvest_date': '2025-03-01',
        }):
            login_user(self.farmer)
            response = create_batch()
            messages = get_flashed_messages(with_categories=True)

        self.assertIsInstance(response, str)
        self.assertTrue(any('farm is quarantined' in message.lower() for _, message in messages))
        self.assertEqual(Batch.query.count(), initial_count)

    def test_fso_can_release_quarantined_farm(self):
        from flask_login import login_user
        from app.main.routes import release_farm_quarantine

        self.farm.status = 'QUARANTINED'
        db.session.commit()

        with self.app.test_request_context(f'/fso/farm/{self.farm.farm_id}/release', method='POST'):
            login_user(self.fso)
            response = release_farm_quarantine(self.farm.farm_id)

        self.assertEqual(response.status_code, 302)
        self.assertEqual(self.farm.status, 'ACTIVE')

    def test_recall_cascades_to_batch_lineage_and_cancels_shipments(self):
        from flask_login import login_user
        from app.main.routes import create_recall
        from app.models import BatchLineage

        children = [
            Batch(
                batch_code=f'BATCH-TEST-001-CHILD-{index}',
                product_id=self.product.product_id,
                batch_type='DERIVED',
                farm_id=None,
                processing_unit_id=self.unit.unit_id,
                initial_quantity_kg=40,
                quantity_kg=40,
                harvest_date=self.batch.harvest_date,
                expiry_date=self.batch.expiry_date,
                status='ACTIVE',
                stage='PACKED',
                created_by=self.processor.user_id,
            )
            for index in (1, 2)
        ]
        db.session.add_all(children)
        db.session.flush()
        db.session.add_all([
            BatchLineage(
                parent_batch_id=self.batch.batch_id,
                child_batch_id=child.batch_id,
                quantity_used_kg=40,
                relation_type='SPLIT',
            )
            for child in children
        ])
        shipments = [
            Shipment(
                batch_id=child.batch_id,
                retailer_id=self.retailer.user_id,
                quantity_kg=10,
                shipped_date=date.today(),
                status=status,
                created_by=self.processor.user_id,
            )
            for child, status in zip(children, ('PENDING', 'IN_TRANSIT'))
        ]
        db.session.add_all(shipments)
        db.session.commit()

        with self.app.test_request_context(
            '/fso/recall/create',
            method='POST',
            data={
                'batch_id': str(children[0].batch_id),
                'severity': 'CLASS_II',
                'reason': 'Contamination found in the shared source lot',
            },
        ):
            login_user(self.fso)
            response = create_recall()

        self.assertEqual(response.status_code, 302)
        self.assertEqual(self.batch.status, 'RECALLED')
        self.assertTrue(all(child.status == 'RECALLED' for child in children))
        self.assertTrue(all(shipment.status == 'CANCELLED' for shipment in shipments))

    def test_existing_open_recall_is_reconciled_across_lineage(self):
        from app import reconcile_open_recalls
        from app.main.routes import _split_batch_transaction
        from app.models import Recall

        _split_batch_transaction(
            self.batch,
            [{'qty': 40}, {'qty': 30}],
            self.processor.user_id,
            self.unit.unit_id,
        )
        recalled_child = Batch.query.filter_by(batch_code='BATCH-TEST-001-S1').one()
        sibling = Batch.query.filter_by(batch_code='BATCH-TEST-001-S2').one()
        recalled_child.status = 'RECALLED'
        recall = Recall(
            recall_code='REC-BATCH-TEST-001-S1',
            batch_id=recalled_child.batch_id,
            issued_by=self.fso.user_id,
            severity='CLASS_II',
            reason='Recall predating lineage cascade',
            status='OPEN',
        )
        db.session.add(recall)
        db.session.commit()

        reconcile_open_recalls()

        self.assertEqual(self.batch.status, 'RECALLED')
        self.assertEqual(recalled_child.status, 'RECALLED')
        self.assertEqual(sibling.status, 'RECALLED')


if __name__ == '__main__':
    unittest.main()
