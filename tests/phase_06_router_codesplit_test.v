// Phase 06 — Router + code splitting: route table → chunk plan.
//
// GOAL: from the route table, produce a chunk plan: what goes in core.wasm
// (runtime + shared components + the landing route) vs. a per-route side chunk
// (lazy routes + their route-local components). Param routes are recognized;
// shared components are hoisted; the plan is the input to phase 07's linking.
//
// See ../../v-web-csr-concept/SCALING.md.
module main

import vcsr.router { Route }

fn test_parses_route_table() {
	plan := router.plan([
		Route{ path: '/', component: 'Home' },
		Route{ path: '/todos', component: 'TodoList' },
	])!
	assert plan.routes.len == 2
	assert plan.route('/').component == 'Home'
}

fn test_recognizes_param_routes() {
	plan := router.plan([Route{ path: '/users/:id', component: 'UserProfile' }])!
	r := plan.route('/users/:id')
	assert r.params == ['id']
}

fn test_landing_route_goes_in_core() {
	plan := router.plan([
		Route{ path: '/', component: 'Home' },
		Route{ path: '/reports', component: 'Reports', lazy: true },
	])!
	assert 'Home' in plan.core_components()
}

fn test_lazy_route_becomes_its_own_chunk() {
	plan := router.plan([
		Route{ path: '/', component: 'Home' },
		Route{ path: '/reports', component: 'Reports', lazy: true },
	])!
	assert plan.has_chunk('reports')
	assert 'Reports' in plan.chunk('reports').components
	assert 'Reports' !in plan.core_components()
}

fn test_shared_component_hoisted_to_core_not_duplicated() {
	// Button used by two routes must live in core, not in either chunk
	plan := router.plan_with_usage([
		Route{ path: '/', component: 'Home', lazy: false },
		Route{ path: '/reports', component: 'Reports', lazy: true },
	], component_usage: {
		'Button': ['/', '/reports']
	})!
	assert 'Button' in plan.core_components()
	assert 'Button' !in plan.chunk('reports').components
}

fn test_route_local_component_stays_in_chunk() {
	plan := router.plan_with_usage([
		Route{ path: '/reports', component: 'Reports', lazy: true },
	], component_usage: {
		'ReportRow': ['/reports']
	})!
	assert 'ReportRow' in plan.chunk('reports').components
	assert 'ReportRow' !in plan.core_components()
}

fn test_chunk_carries_only_its_own_templates() {
	plan := router.plan_with_usage([
		Route{ path: '/', component: 'Home' },
		Route{ path: '/reports', component: 'Reports', lazy: true },
	], component_usage: {
		'Button':    ['/', '/reports']
		'ReportRow': ['/reports']
	})!
	c := plan.chunk('reports')
	assert c.components == ['Reports', 'ReportRow'] // Button is shared → core
}

fn test_wildcard_fallback_route() {
	plan := router.plan([Route{ path: '/*', component: 'NotFound' }])!
	assert plan.fallback().component == 'NotFound'
}
