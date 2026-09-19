'use strict';
'require view';
'require fs';
'require poll';
'require dom';

function loadStatus() {
	return fs.exec('/usr/sbin/sbe-status', [ '--json' ]).then(function(result) {
		if (result.code !== 0)
			throw new Error(result.stderr || _('Status collector exited with code %d').format(result.code));
		return JSON.parse(result.stdout || '{}');
	}).catch(function(error) {
		return { error: error.message || String(error) };
	});
}

function display(value, fallback) {
	return value !== undefined && value !== null && value !== false && value !== ''
		? String(value) : (fallback || '—');
}

function friendlyToken(value) {
	var labels = {
		'ram-trial': _('RAM trial'),
		'persistent': _('Persistent operation'),
		'persistent-degraded': _('Storage degraded'),
		'boot-argument': _('Stock U-Boot boot argument'),
		'http-chainloader-p27': _('HTTP U-Boot (p27)'),
		'blue_on': _('Blue (steady)'),
		'blue_breath': _('Blue (breathing)'),
		'blue_blink': _('Blue (blinking)'),
		'white_on': _('White (steady)'),
		'white_breath': _('White (breathing)'),
		'white_blink': _('White (blinking)'),
		'yellow_on': _('Yellow (steady)'),
		'yellow_breath': _('Yellow (breathing)'),
		'yellow_blink': _('Yellow (blinking)'),
		'green_on': _('Green (steady)'),
		'green_breath': _('Green (breathing)'),
		'green_blink': _('Green (blinking)'),
		'red_on': _('Red (steady)'),
		'red_breath': _('Red (breathing)'),
		'red_blink': _('Red (blinking)'),
		'purple_on': _('Purple (steady)'),
		'purple_breath': _('Purple (breathing)'),
		'purple_blink': _('Purple (blinking)'),
		'all_off': _('Off'),
		'ready': _('System ready'),
		'connecting': _('Connecting'),
		'connected': _('Connected'),
		'disconnected': _('Disconnected'),
		'thermal': _('Thermal'),
		'upgrade': _('Upgrade'),
		'reset': _('Factory reset'),
		'base': _('Normal status'),
		'error': _('Fault'),
		'none': _('None'),
		'unknown': _('Unknown'),
		'unset': _('Not set'),
		'auto': _('Automatic')
	};
	return labels[String(value)] || display(value);
}

function temperature(value) {
	return typeof(value) === 'number' ? '%d °C'.format(value) : '—';
}

function rpm(value) {
	return typeof(value) === 'number' ? '%d RPM'.format(value) : '—';
}

function seconds(value) {
	return typeof(value) === 'number' ? _('%d seconds').format(value) : '—';
}

function duration(value) {
	if (typeof(value) !== 'number')
		return '—';

	var days = Math.floor(value / 86400);
	var hours = Math.floor((value % 86400) / 3600);
	var minutes = Math.floor((value % 3600) / 60);
	var parts = [];

	if (days)
		parts.push(_('%d days').format(days));
	if (hours || days)
		parts.push(_('%d hours').format(hours));
	parts.push(_('%d minutes').format(minutes));
	return parts.join(' ');
}

function percent(value) {
	return typeof(value) === 'number' ? '%d%%'.format(value) : '—';
}

function age(value) {
	return typeof(value) === 'number' ? _('%d seconds ago').format(value) : '—';
}

function chainCount(value) {
	var mask = Number(value);
	var count = 0;
	if (!isFinite(mask) || mask < 0)
		return null;
	mask = Math.floor(mask);
	while (mask > 0) {
		count += mask & 1;
		mask = Math.floor(mask / 2);
	}
	return count;
}

function radioChains(value) {
	var masks = String(value || '').split(',');
	if (masks.length < 3)
		return friendlyToken(value);
	var counts = masks.slice(0, 3).map(chainCount);
	if (counts.some(function(count) { return count === null; }))
		return friendlyToken(value);
	return _('2.4 / 6 / 5 GHz: %d / %d / %d chains').format(counts[0], counts[1], counts[2]);
}

function state(text, level) {
	var prefix = level === 'good' ? '✓ ' : (level === 'bad' ? '✕ ' :
		(level === 'warn' ? '⚠ ' : ''));
	return E('strong', {}, [ prefix + text ]);
}

function yesNoState(ok, goodText, badText) {
	return state(ok ? goodText : badText, ok ? 'good' : 'bad');
}

function field(label, value) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left' }, [ label ]),
		E('div', { 'class': 'td left' }, Array.isArray(value) ? value : [ value ])
	]);
}

function section(title, summary, fields) {
	return E('section', { 'class': 'cbi-section' }, [
		E('h3', {}, summary ? [ title, ' — ', summary ] : [ title ]),
		E('div', { 'class': 'table' }, fields)
	]);
}

/* Keep layout local to this view. Text, surfaces and controls inherit the
 * active LuCI theme; only the data series have fixed, distinguishable colors. */
var dashboardStyle = '.sbe-hardware .sbe-hw-summary{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:1em}' +
	'.sbe-hardware .sbe-hw-summary .cbi-section{margin:0;min-width:0;padding:1em}' +
	'.sbe-hardware .sbe-hw-value{display:block;font-size:1.65em;line-height:1.5;overflow-wrap:anywhere}' +
	'.sbe-hardware .sbe-hw-label{display:block;margin-bottom:.35em}' +
	'.sbe-hardware .sbe-hw-charts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1em;margin-top:1em}' +
	'.sbe-hardware .sbe-hw-chart{min-width:0;margin:0;padding:1em}' +
	'.sbe-hardware .sbe-hw-chart svg{display:block;width:100%;height:230px;overflow:visible;color:inherit}' +
	'.sbe-hardware .sbe-hw-chart svg text{fill:currentColor;font-family:inherit;font-size:11px}' +
	'.sbe-hardware .sbe-hw-legend{display:flex;flex-wrap:wrap;gap:.5em;margin:.5em 0}' +
	'.sbe-hardware .sbe-hw-legend button{display:inline-flex;align-items:center;gap:.4em;white-space:normal;margin:0}' +
	'.sbe-hardware .sbe-hw-legend button[aria-pressed="false"]{opacity:.55;text-decoration:line-through}' +
	'.sbe-hardware .sbe-hw-swatch{display:inline-block;width:1em;border-top:3px solid;flex-shrink:0}' +
	'.sbe-hardware .sbe-hw-chart-note{min-height:2.5em;margin:.5em 0 0}' +
	'.sbe-hardware .sbe-hw-details{margin-top:1em}' +
	'.sbe-hardware .sbe-hw-details>summary{cursor:pointer;font-weight:bold;padding:.8em 0}' +
	'.sbe-hardware .sbe-hw-status-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1em;margin-top:1em}' +
	'.sbe-hardware .sbe-hw-status-grid>section{margin:0;min-width:0}' +
	'.sbe-hardware .td{overflow-wrap:anywhere}' +
	'.sbe-hardware .sbe-hw-wireless .td:first-child{white-space:nowrap;min-width:5em}' +
	'@media(min-width:1051px){.sbe-hardware .sbe-hw-legend{min-height:5.5em;align-content:flex-start}}' +
	'@media(max-width:1050px){.sbe-hardware .sbe-hw-charts{grid-template-columns:1fr}}' +
	'@media(max-width:700px){.sbe-hardware .sbe-hw-summary{grid-template-columns:repeat(2,minmax(0,1fr))}' +
	'.sbe-hardware .sbe-hw-status-grid{grid-template-columns:1fr}}';

function number(value) {
	return typeof(value) === 'number' && isFinite(value) ? value : null;
}

function thermalIsFresh(data) {
	var thermal = data.thermal || {};
	var sample = number(thermal.sample_uptime_seconds);
	var uptime = number((data.device || {}).uptime_seconds);
	var interval = number(thermal.policy_interval) || 10;
	return thermal.available && sample !== null && uptime !== null &&
		sample <= uptime && uptime - sample <= interval * 2 + 20;
}

function HardwareHistory() {
	this.samples = [];
	this.uptime = null;
	this.observedAt = performance.now();
	this.interval = 10;
}

HardwareHistory.prototype.time = function() {
	return (this.uptime || 0) + Math.max(0, (performance.now() - this.observedAt) / 1000);
};

HardwareHistory.prototype.update = function(data) {
	var uptime = number((data.device || {}).uptime_seconds);
	var thermal = data.thermal || {};
	if (uptime !== null) {
		if (this.uptime !== null && uptime < this.uptime)
			this.samples = [];
		this.uptime = uptime;
		this.observedAt = performance.now();
	}
	this.interval = number(thermal.policy_interval) || this.interval;
	var cutoff = this.time() - 900;
	this.samples = this.samples.filter(function(sample) { return sample.time >= cutoff; });
	// The daemon publishes a bounded, atomic snapshot, so reloads and missed
	// browser polls recover real samples. Old firmware keeps the local fallback.
	if (Array.isArray(thermal.history) && uptime !== null) {
		var previousTime = -1, valid = thermal.history.length <= 91;
		var samples = thermal.history.map(function(row) {
			var time = row && number(row.time), sample = { time: time };
			if (time === null || time <= previousTime || time > uptime)
				valid = false;
			previousTime = time;
			[ 'cpu', 'wifi0', 'wifi1', 'wifi2', 'iot', 'actual', 'target' ].forEach(function(key) {
				sample[key] = number(row && row[key]);
			});
			return sample;
		});
		if (valid) {
			this.samples = samples.filter(function(sample) { return sample.time >= cutoff; });
			return;
		}
	}
	if (!thermalIsFresh(data))
		return;
	var time = thermal.sample_uptime_seconds;
	var previous = this.samples[this.samples.length - 1];
	if (previous && time <= previous.time)
		return;
	var temps = thermal.temperatures_c || {};
	var fan = thermal.fan || {};
	this.samples.push({ time: time, cpu: number(temps.cpu), wifi0: number(temps.wifi0),
		wifi1: number(temps.wifi1), wifi2: number(temps.wifi2), iot: number(temps.iot),
		actual: fan.rpm_stale ? null : number(fan.actual_rpm), target: number(fan.target_rpm) });
	// Bound storage even if a future backend increases its sample rate.
	this.samples = this.samples.slice(-901);
};

function svgElement(tag, attrs, text) {
	var node = document.createElementNS('http://www.w3.org/2000/svg', tag);
	Object.keys(attrs || {}).forEach(function(key) { node.setAttribute(key, attrs[key]); });
	if (text !== undefined)
		node.textContent = text;
	return node;
}

function HardwareChart(title, series, history, unit) {
	this.series = series;
	this.history = history;
	this.unit = unit;
	this.thresholds = [];
	this.graph = svgElement('svg', { role: 'img', 'aria-label': title });
	this.note = E('p', { 'class': 'cbi-map-descr sbe-hw-chart-note' });
	this.thresholdKey = E('div', { 'class': 'cbi-map-descr sbe-hw-legend' });
	var self = this;
	this.legend = E('div', { 'class': 'sbe-hw-legend' }, series.map(function(item) {
		item.valueNode = E('span', {}, [ '—' ]);
		item.legendNode = E('button', { 'type': 'button', 'class': 'cbi-button',
			'aria-pressed': item.hidden ? 'false' : 'true',
			'click': function(event) {
				item.hidden = !item.hidden;
				event.currentTarget.setAttribute('aria-pressed', item.hidden ? 'false' : 'true');
				self.draw();
			}
		}, [ E('span', { 'class': 'sbe-hw-swatch', 'aria-hidden': 'true',
			'style': 'border-color:' + item.color + (item.dash ? ';border-top-style:dashed' : '') }),
			item.label, item.valueNode ]);
		return item.legendNode;
	}));
	this.node = E('section', { 'class': 'cbi-section sbe-hw-chart' }, [
		E('h3', {}, [ title ]), this.legend, this.graph, this.thresholdKey, this.note
	]);
}

HardwareChart.prototype.draw = function() {
	var width = Math.max(260, this.graph.clientWidth || 600);
	var height = 230, left = 44, right = width - 12, top = 18, bottom = height - 30;
	var now = this.history.time(), start = now - 900;
	var samples = this.history.samples;
	var maximum = this.unit === 'RPM' ? 5000 : 120;
	this.series.forEach(function(series) {
		if (!series.hidden)
			samples.forEach(function(sample) {
				if (sample[series.key] !== null)
					maximum = Math.max(maximum, sample[series.key]);
			});
	});
	maximum = Math.ceil(maximum / (this.unit === 'RPM' ? 1000 : 20)) * (this.unit === 'RPM' ? 1000 : 20);
	var x = function(time) { return left + (right - left) * (time - start) / 900; };
	var y = function(value) { return bottom - (bottom - top) * value / maximum; };
	var nodes = [ svgElement('title', {}, this.graph.getAttribute('aria-label')) ];
	for (var i = 0; i <= 4; i++) {
		var value = maximum * i / 4;
		nodes.push(svgElement('line', { x1: left, x2: right, y1: y(value), y2: y(value),
			stroke: 'currentColor', opacity: '.18' }));
		nodes.push(svgElement('text', { x: left - 7, y: y(value) + 4, 'text-anchor': 'end' }, String(value)));
		var secondsAgo = (4 - i) * 225;
		nodes.push(svgElement('text', { x: x(now - secondsAgo), y: height - 8,
			'text-anchor': i === 0 ? 'start' : (i === 4 ? 'end' : 'middle') },
			i === 4 ? _('Now') : '-%d:%s'.format(Math.floor(secondsAgo / 60), ('0' + secondsAgo % 60).slice(-2))));
	}
	var gap = this.history.interval * 2.5;
	this.series.forEach(function(series) {
		if (series.hidden)
			return;
		var path = '', previous = null;
		samples.forEach(function(sample) {
			var value = sample[series.key];
			if (value === null || sample.time < start || sample.time > now) {
				previous = null;
				return;
			}
			var continuous = previous !== null && sample.time - previous <= gap;
			path += (continuous ? ' L ' : ' M ') + x(sample.time).toFixed(2) + ' ' + y(value).toFixed(2);
			previous = sample.time;
		});
		nodes.push(svgElement('path', { d: path, fill: 'none', stroke: series.color,
			'stroke-width': 2, 'stroke-dasharray': series.dash || '', 'vector-effect': 'non-scaling-stroke' }));
		var last = samples[samples.length - 1];
		if (last && last[series.key] !== null && now - last.time <= gap)
			nodes.push(svgElement('circle', { cx: x(last.time), cy: y(last[series.key]), r: 3, fill: series.color }));
	});
	this.thresholds.forEach(function(threshold) {
		if (number(threshold.value) === null)
			return;
		nodes.push(svgElement('line', { x1: left, x2: right, y1: y(threshold.value), y2: y(threshold.value),
			stroke: 'currentColor', opacity: '.65', 'stroke-dasharray': threshold.dash }));
	});
	if (!samples.length)
		nodes.push(svgElement('text', { x: (left + right) / 2, y: (top + bottom) / 2,
			'text-anchor': 'middle' }, _('Waiting for fresh samples')));
	this.graph.setAttribute('viewBox', '0 0 ' + width + ' ' + height);
	while (this.graph.firstChild)
		this.graph.removeChild(this.graph.firstChild);
	nodes.forEach(function(node) { this.graph.appendChild(node); }, this);
};

HardwareChart.prototype.update = function(data, thresholds) {
	var thermal = data.thermal || {}, temperatures = thermal.temperatures_c || {}, fan = thermal.fan || {};
	var fresh = thermalIsFresh(data);
	var readings = this.unit === 'RPM' ? { actual: fan.rpm_stale ? null : fan.actual_rpm, target: fan.target_rpm } : temperatures;
	this.series.forEach(function(series) {
		series.valueNode.textContent = fresh && number(readings[series.key]) !== null ?
			'%d %s'.format(readings[series.key], this.unit) : '—';
		series.legendNode.style.display = series.optional && !this.history.samples.some(function(sample) {
			return number(sample[series.key]) !== null;
		}) ? 'none' : '';
	}, this);
	this.thresholds = thresholds || [];
	dom.content(this.thresholdKey, this.thresholds.filter(function(threshold) {
		return number(threshold.value) !== null;
	}).map(function(threshold) {
		return E('span', {}, [ '%s: %d °C'.format(threshold.label, threshold.value) ]);
	}));
	this.draw();
};

function thermalSummary(thermal) {
	thermal = thermal || {};
	var fan = thermal.fan || {};
	var interval = number(thermal.policy_interval) || 10;
	var level = number(thermal.state);
	if (!thermal.available)
		return state(_('Waiting for thermal service'), 'warn');
	if (level >= 10)
		return state(_('Temperature too high'), 'bad');
	if (thermal.config_fault || thermal.sensor_fault || fan.fault || fan.rpm_stale)
		return state(_('Attention required'), 'bad');
	if (number(thermal.updated_seconds_ago) === null || thermal.updated_seconds_ago > interval * 2 + 20)
		return state(_('Status is stale'), 'warn');
	if (thermal.radio_mask_fault)
		return state(_('Radio chain reduction failed'), 'warn');
	if (level >= 7)
		return state(_('High-temperature operation'), 'warn');
	return state(thermal.early_fan_active ? _('Early cooling') : _('Normal'), 'good');
}

function deviceSection(device, runtime) {
	device = device || {};
	runtime = runtime || {};
	var mode = runtime.ram_only ? state(_('RAM trial'), 'good') :
		(runtime.persistent_active ? state(_('Persistent operation'), 'good') : state(friendlyToken(runtime.mode), 'warn'));

	var persistentRequest = runtime.persistent_requested ?
		(runtime.persistent_active ? state(_('Yes (active)'), 'good') : state(_('Yes (not active)'), 'bad')) : _('No');
	var emmcState = runtime.unexpected_emmc_read_write ?
		state(_('Unexpected read-write mount detected'), 'bad') :
		(runtime.emmc_read_write_expected ? state(_('p30 configuration partition (normal)'), 'good') :
			(runtime.emmc_read_write ? state(_('Read-write mount detected'), 'warn') : state(_('Not detected'), 'good')));

	return section(_('Device and runtime'), mode, [
		field(_('Device model'), display(device.model)),
		field(_('QSDK version'), display(device.sdk)),
		field(_('Firmware version'), display(device.firmware)),
		field(_('Kernel version'), display(device.kernel)),
		field(_('Uptime'), duration(device.uptime_seconds)),
		field(_('Root filesystem'), display(runtime.root_source)),
		field(_('Configuration source'), display(runtime.config_source)),
		field(_('Persistent boot requested'), persistentRequest),
		field(_('Persistent selection source'), friendlyToken(runtime.persistent_source)),
		field(_('eMMC read-write mount'), emmcState)
	]);
}

function accelerationSection(acceleration) {
	acceleration = acceleration || {};
	var engines = [
		[ 'NSS', acceleration.nss ],
		[ 'PPE', acceleration.ppe ],
		[ 'ECM', acceleration.ecm ],
		[ 'SSDK', acceleration.ssdk ]
	];
	var loaded = engines.filter(function(engine) {
		return engine[1] && engine[1].loaded;
	}).length;
	var fields = engines.map(function(engine) {
		return field(engine[0], yesNoState(engine[1] && engine[1].loaded,
			_('Loaded'), _('Not loaded')));
	});
	var ovs = acceleration.ovs_dependency || {};
	fields.push(field(_('OVS dependency'), ovs.loaded ? state(_('Module loaded'), 'good') : _('Not loaded (default)')));
	fields.push(field(_('OVS acceleration policy'), ovs.policy_enabled ? state(_('Enabled'), 'warn') :
		_('Disabled (%s)').format(display(ovs.policy_value))));

	return section(_('Hardware acceleration'), state(_('%d/4 drivers loaded').format(loaded),
		loaded === 4 ? 'good' : 'warn'), fields);
}

function thermalSection(thermal) {
	thermal = thermal || {};
	var temps = thermal.temperatures_c || {};
	var fan = thermal.fan || {};
	var policyInterval = typeof(thermal.policy_interval) === 'number' ? thermal.policy_interval : 10;
	return section(_('Temperature and fan'), thermalSummary(thermal), [
		field(_('Cooling profile'), thermal.cooling_profile === 'balanced' ? _('Balanced') :
			(thermal.cooling_profile === 'factory' ? _('Factory') : _('Unknown'))),
		field(_('CPU temperature'), temperature(temps.cpu)),
		number(temps.iot) !== null ? field(_('IoT temperature'), temperature(temps.iot)) : null,
		field(_('2.4 GHz radio temperature'), temperature(temps.wifi0)),
		field(_('6 GHz radio temperature'), temperature(temps.wifi1)),
		field(_('5 GHz radio temperature'), temperature(temps.wifi2)),
		field(_('Status age'), age(thermal.updated_seconds_ago)),
		field(_('Thermal sampling interval'), seconds(policyInterval)),
		field(_('Cooling level'), display(thermal.state, _('Unavailable'))),
		field(_('Policy fan speed'), rpm(fan.policy_rpm)),
		field(_('Target fan speed'), rpm(fan.target_rpm)),
		field(_('Actual fan speed'), rpm(fan.actual_rpm)),
		field(_('Fan speed sample age'), age(fan.rpm_age_seconds)),
		field(_('Allowed fan speed range'), typeof(fan.minimum_rpm) === 'number' && typeof(fan.maximum_rpm) === 'number' ?
			'%d–%d RPM'.format(fan.minimum_rpm, fan.maximum_rpm) : '—'),
		field(_('PWM duty value'), display(fan.pwm_duty)),
		field(_('Fan fault / recovery samples'), typeof(fan.bad_samples) === 'number' && typeof(fan.good_samples) === 'number' ?
			'%d / %d'.format(fan.bad_samples, fan.good_samples) : '—'),
		field(_('Fan status'), fan.fault ? state(_('Fault: %s').format(friendlyToken(fan.fault_reason)), 'bad') :
			(fan.rpm_stale ? state(_('Fan speed data is stale'), 'bad') :
				state(thermal.available ? _('Normal') : _('Unavailable'), thermal.available ? 'good' : 'warn'))),
		field(_('Thermal configuration'), thermal.config_fault ? state(_('Invalid: %s').format(friendlyToken(thermal.config_fault_reason)), 'bad') :
			state(thermal.available ? _('Valid') : _('Unavailable'), thermal.available ? 'good' : 'warn')),
		field(_('Temperature sensors'), thermal.sensor_fault ? state(_('Read error'), 'bad') :
			state(thermal.available ? _('Normal') : _('Unavailable'), thermal.available ? 'good' : 'warn')),
		field(_('Critical-temperature samples'), display(thermal.critical_state_samples)),
		field(_('Radio transmit chains'), thermal.radio_mask_fault ? state(_('Configuration failed'), 'bad') :
			radioChains(thermal.radio_txchainmask))
	].filter(function(row) { return row !== null; }));
}

function wirelessRadio(radio) {
	radio = radio || {};
	if (!radio.available)
		return state(_('Configuration unavailable'), 'warn');

	var activity;
	if (!radio.enabled || !radio.ap_configured)
		activity = _('Disabled');
	else if (radio.ap_enabled)
		activity = state(_('Enabled, AP is running'), 'good');
	else
		activity = state(_('Enabled in configuration, but AP is not running'), 'bad');
	return [
		activity,
		' · ', _('Interface'), ' ', display(radio.interface),
		' · ', _('Runtime state'), ' ', friendlyToken(radio.runtime_state),
		' · ', _('Driver'), ' ', radio.driver_present ? _('Present') : _('Missing'),
		' · ', _('Channel'), ' ', friendlyToken(radio.channel),
		' · ', display(radio.width),
		' · ', _('Country/region'), ' ', friendlyToken(radio.country),
		' · ', _('SSID'), ' ', display(radio.ssid, _('Not set')),
		' · ', _('Encryption'), ' ', friendlyToken(radio.encryption)
	];
}

function wirelessSection(wireless) {
	wireless = Array.isArray(wireless) ? wireless : [];
	var configured = wireless.filter(function(radio) { return radio.available; }).length;
	var requested = wireless.filter(function(radio) { return radio.enabled && radio.ap_configured; }).length;
	var enabled = wireless.filter(function(radio) { return radio.ap_enabled; }).length;
	var fields = wireless.map(function(radio) {
		return field(display(radio.label, radio.section), wirelessRadio(radio));
	});

	if (!fields.length)
		fields.push(field(_('Wireless status'), state(_('No data available'), 'warn')));

	return section(_('Wireless hardware'), state(_('%d/%d configured APs running; %d/3 radio configurations present').format(enabled, requested, configured),
		configured !== 3 || enabled !== requested ? 'bad' : (enabled ? 'good' : 'warn')), fields);
}

function watchdogSection(watchdog) {
	watchdog = watchdog || {};
	var healthy = watchdog.available && watchdog.health === 'ok';
	var summary = !watchdog.enabled ? _('Disabled (optional)') :
		(!watchdog.available ? state(_('Waiting for watchdog status'), 'warn') :
			(healthy ? state(_('Normal'), 'good') : state(_('Warnings present'), 'warn')));

	return section(_('Local watchdog and resources'), summary, [
		field(_('Local resource watchdog'), watchdog.enabled ? _('Enabled') : _('Disabled (optional)')),
		field(_('Status age'), age(watchdog.updated_seconds_ago)),
		field(_('/tmp usage'), percent(watchdog.tmp_percent)),
		field(_('Connection tracking usage'), percent(watchdog.conntrack_percent)),
		field(_('File handle usage'), percent(watchdog.file_percent)),
		field(_('Zombie processes'), display(watchdog.zombie_count, '0')),
		field(_('Missing processes'), display(watchdog.missing_processes, _('None'))),
		field(_('Warnings'), display(watchdog.warnings, _('None')))
	]);
}

function ledSection(led) {
	led = led || {};
	var failed = led.state === 'error' || led.source === 'error' ||
		String(led.source || '').indexOf('invalid') >= 0;
	var summary = !led.available ? state(_('Status unavailable'), 'warn') :
		(failed ? state(_('Attention required'), 'bad') : state(_('Normal'), 'good'));
	return section(_('RGB status LED'), summary, [
		field(_('State'), friendlyToken(led.state)),
		field(_('Pattern'), friendlyToken(led.pattern)),
		field(_('Pattern source'), friendlyToken(led.source)),
		field(_('Network status'), friendlyToken(led.base_state)),
		field(_('Last state change'), age(led.updated_seconds_ago))
	]);
}

return view.extend({
	load: loadStatus,

	render: function(data) {
		var history = new HardwareHistory();
		var temperatures = new HardwareChart(_('Temperature trends'), [
			{ key: 'cpu', label: _('CPU temperature'), color: '#3788dd' },
			{ key: 'wifi0', label: '2.4 GHz', color: '#cc7919' },
			{ key: 'wifi2', label: '5 GHz', color: '#158d79' },
			{ key: 'wifi1', label: '6 GHz', color: '#ae63c5' },
			{ key: 'iot', label: _('IoT temperature'), color: '#cc566e', optional: true }
		], history, '°C');
		var fan = new HardwareChart(_('Fan speed trends'), [
			{ key: 'actual', label: _('Actual fan speed'), color: '#3788dd' },
			{ key: 'target', label: _('Target fan speed'), color: 'currentColor', dash: '7 4' }
		], history, 'RPM');
		var error = E('div');
		var cards = {}, cardLabels = { cpu: _('CPU temperature'), radio: _('Highest radio temperature'),
			fan: _('Actual fan speed'), cooling: _('Cooling status') };
		var summary = E('div', { 'class': 'sbe-hw-summary' }, Object.keys(cardLabels).map(function(key) {
			cards[key] = E('strong', { 'class': 'sbe-hw-value' }, [ '—' ]);
			return E('section', { 'class': 'cbi-section' }, [ E('span', { 'class': 'sbe-hw-label' }, [ cardLabels[key] ]), cards[key] ]);
		}));
		var status = E('div', { 'class': 'sbe-hw-status-grid' });
		var wireless = E('div', { 'class': 'sbe-hw-wireless' }), detailBody = E('div');
		var details = E('details', { 'class': 'sbe-hw-details' }, [
			E('summary', {}, [ _('Device and diagnostic details') ]), detailBody
		]);
		var content = E('div', { 'class': 'cbi-map sbe-hardware' }, [
			E('style', {}, [ dashboardStyle ]), E('h2', {}, [ _('Hardware Status') ]),
			E('p', { 'class': 'cbi-map-descr' }, [ _('Charts show the last 15 minutes retained in router memory. History resets when the thermal service or router restarts. Select a legend to show or hide a series.') ]),
			error, summary, E('div', { 'class': 'sbe-hw-charts' }, [ temperatures.node, fan.node ]),
			status, wireless, details
		]);
		function update(updated) {
			history.update(updated);
			var thermal = updated.thermal || {}, readings = thermal.temperatures_c || {};
			var fresh = thermalIsFresh(updated), fanData = thermal.fan || {};
			dom.content(error, updated.error ? E('p', { 'class': 'alert-message error' }, [
				_('Unable to read hardware status'), ': ', updated.error ]) : []);
			cards.cpu.textContent = fresh ? temperature(readings.cpu) : '—';
			var radioTemps = [ readings.wifi0, readings.wifi1, readings.wifi2 ].filter(function(value) { return number(value) !== null; });
			cards.radio.textContent = fresh && radioTemps.length ? temperature(Math.max.apply(Math, radioTemps)) : '—';
			cards.fan.textContent = fresh && !fanData.rpm_stale ? rpm(fanData.actual_rpm) : '—';
			dom.content(cards.cooling, thermal.available && !fresh ? state(_('Status is stale'), 'warn') : thermalSummary(thermal));
			var thresholds = [];
			if (fresh && !thermal.config_fault && thermal.cooling_profile === 'balanced') {
				thresholds = [ { value: thermal.early_start_c, label: _('Fan start'), dash: '8 4' },
					{ value: thermal.early_release_c, label: _('Early cooling release'), dash: '2 4' } ];
			}
			temperatures.update(updated, thresholds);
			fan.update(updated);
			dom.content(temperatures.note, [ _('Temperature readings are four-sample averages.'), ' ',
				_('This page refreshes once per second; the thermal service samples every 10 seconds.') ]);
			dom.content(fan.note, fresh && !thermal.config_fault && thermal.cooling_profile === 'balanced' ? [
				_('Early cooling requests %d RPM at %d °C and releases at or below %d °C. Higher cooling and fault protection take priority.').format(
					thermal.early_fan_rpm, thermal.early_start_c, thermal.early_release_c) ] : [
				thermal.cooling_profile === 'factory' ? _('Fan speed follows the factory thermal policy.') : _('Waiting for fresh samples') ]);
			dom.content(status, [ accelerationSection(updated.acceleration), ledSection(updated.led) ]);
			dom.content(wireless, wirelessSection(updated.wireless));
			dom.content(detailBody, [ deviceSection(updated.device, updated.runtime), thermalSection(thermal), watchdogSection(updated.watchdog) ]);
		}
		update(data);
		var refreshing = false;

		poll.add(function() {
			if (refreshing)
				return Promise.resolve();

			refreshing = true;
			return loadStatus().then(function(updated) {
				update(updated);
				refreshing = false;
			}).catch(function(error) {
				refreshing = false;
				throw error;
			});
		}, 1);
		// The graph uses real pixel geometry so labels stay legible on narrow
		// screens. No global resize handler or theme override is needed.
		if (typeof(ResizeObserver) !== 'undefined') {
			var observer = new ResizeObserver(function() { temperatures.draw(); fan.draw(); });
			observer.observe(content);
			window.addEventListener('pagehide', function() { observer.disconnect(); }, { once: true });
		}

		return content;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
