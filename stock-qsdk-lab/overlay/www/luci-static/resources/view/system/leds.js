'use strict';
'require view';
'require form';
'require fs';
'require poll';
'require dom';

var patterns = [
	[ 'blue_on', _('Blue (steady)') ],
	[ 'blue_breath', _('Blue (breathing)') ],
	[ 'blue_blink', _('Blue (blinking)') ],
	[ 'white_on', _('White (steady)') ],
	[ 'white_breath', _('White (breathing)') ],
	[ 'white_blink', _('White (blinking)') ],
	[ 'yellow_on', _('Yellow (steady)') ],
	[ 'yellow_breath', _('Yellow (breathing)') ],
	[ 'yellow_blink', _('Yellow (blinking)') ],
	[ 'green_on', _('Green (steady)') ],
	[ 'green_breath', _('Green (breathing)') ],
	[ 'green_blink', _('Green (blinking)') ],
	[ 'red_on', _('Red (steady)') ],
	[ 'red_breath', _('Red (breathing)') ],
	[ 'red_blink', _('Red (blinking)') ],
	[ 'purple_on', _('Purple (steady)') ],
	[ 'purple_breath', _('Purple (breathing)') ],
	[ 'purple_blink', _('Purple (blinking)') ],
	[ 'red_white_blink', _('Red and white (alternating blink)') ],
	[ 'alternate_blink', _('Multicolor (alternating blink)') ],
	[ 'alternate_breath', _('Multicolor (alternating breath)') ],
	[ 'all_off', _('Off') ]
];

var tokenLabels = {
	'ready': _('System ready'),
	'connecting': _('Connecting to WAN'),
	'connected': _('WAN connected'),
	'disconnected': _('WAN disconnected'),
	'reset': _('Factory reset'),
	'upgrade': _('Firmware upgrade'),
	'error': _('Hardware fault'),
	'thermal': _('Thermal protection'),
	'base': _('Normal status'),
	'disabled': _('Normal LED disabled'),
	'unknown': _('Unknown')
};

function labelToken(value) {
	var token = String(value || 'unknown');
	for (var i = 0; i < patterns.length; i++)
		if (patterns[i][0] === token)
			return patterns[i][1];
	return tokenLabels[token] || token;
}

function loadStatus() {
	return fs.exec('/usr/sbin/sbe-status', [ '--json' ]).then(function(result) {
		if (result.code !== 0)
			throw new Error(result.stderr || _('Status collection failed'));
		return JSON.parse(result.stdout || '{}').led || {};
	}).catch(function(error) {
		return { error: error.message || String(error) };
	});
}

function statusField(name, value) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left' }, [ name ]),
		E('div', { 'class': 'td left' }, [ value ])
	]);
}

function renderCurrentStatus(led) {
	if (led.error) {
		return E('section', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('Current LED pattern') ]),
			E('div', { 'class': 'alert-message warning' }, [ _('Temporarily unavailable:'), ' ', led.error ])
		]);
	}

	var available = led.available === true;
	return E('section', { 'class': 'cbi-section' }, [
		E('h3', {}, [
			_('Current LED pattern'), ' — ',
			E('strong', {}, [ available ? labelToken(led.pattern) : _('Waiting for status service') ])
		]),
		E('div', { 'class': 'table' }, [
			statusField(_('Current state'), labelToken(led.state)),
			statusField(_('Active pattern'), labelToken(led.pattern)),
			statusField(_('Control source'), labelToken(led.source)),
			statusField(_('Normal base state'), labelToken(led.base_state)),
			statusField(_('Last update'), typeof(led.updated_seconds_ago) === 'number' ?
				_('%d seconds ago').format(led.updated_seconds_ago) : '—')
		]),
		E('p', { 'class': 'cbi-map-descr' }, [
			_('Status updates every second. Overheating, hardware faults, firmware upgrades and factory resets take precedence over normal network indications.')
		])
	]);
}

function addPatternOption(section, tab, option, title, description, defaultValue) {
	var field = section.taboption(tab, form.ListValue, option, title, description);
	for (var i = 0; i < patterns.length; i++)
		field.value(patterns[i][0], patterns[i][1]);
	field.default = defaultValue;
	field.rmempty = false;
	return field;
}

return view.extend({
	load: loadStatus,

	render: function(led) {
		var map = new form.Map('sbe-hardware', _('SBE1V1K Status LED'),
			_('Choose the status LED pattern for network and maintenance events. Changes take effect after Save & Apply.'));
		var section = map.section(form.NamedSection, 'status', 'led', _('LED pattern rules'));
		var option;

		section.anonymous = true;
		section.addremove = false;
		section.tab('general', _('General settings'));
		section.tab('network', _('Network status'));
		section.tab('safety', _('Safety and maintenance'));

		option = section.taboption('general', form.Flag, 'enabled', _('Enable normal status LED'),
			_('When disabled, normal network states do not light the LED. High-temperature, hardware fault, upgrade and factory-reset indications remain active.'));
		option.default = option.enabled;
		option.rmempty = false;

		option = section.taboption('general', form.Flag, 'track_wan', _('Track WAN status automatically'),
			_('When enabled, distinguish connecting, connected and disconnected states. When disabled, always use the System ready pattern.'));
		option.default = option.enabled;
		option.rmempty = false;

		addPatternOption(section, 'network', 'ready', _('System ready'),
			_('Used when WAN tracking is disabled.'), 'blue_on');
		addPatternOption(section, 'network', 'connecting', _('Connecting to WAN'),
			_('Used while the WAN connection is not established.'), 'blue_breath');
		addPatternOption(section, 'network', 'connected', _('WAN connected'),
			_('Used when the WAN connection is established.'), 'blue_on');
		addPatternOption(section, 'network', 'disconnected', _('WAN disconnected'),
			_('Used when an established WAN connection is lost.'), 'red_blink');

		addPatternOption(section, 'safety', 'reset', _('Factory reset'),
			_('Used while restoring factory settings.'), 'red_white_blink');
		addPatternOption(section, 'safety', 'upgrade', _('Firmware upgrade'),
			_('Used while upgrading the firmware.'), 'alternate_breath');
		addPatternOption(section, 'safety', 'error', _('Hardware fault'),
			_('Used when the thermal policy or hardware status reports a serious fault. A prominent red pattern is recommended.'), 'red_on');

		var current = E('div', {}, [ renderCurrentStatus(led) ]);
		var refreshing = false;
		poll.add(function() {
			if (refreshing)
				return Promise.resolve();
			refreshing = true;
			return loadStatus().then(function(updated) {
				dom.content(current, renderCurrentStatus(updated));
				refreshing = false;
			}).catch(function(error) {
				refreshing = false;
				throw error;
			});
		}, 1);

		return map.render().then(function(formNode) {
			return E('div', {}, [ current, formNode ]);
		});
	}
});
