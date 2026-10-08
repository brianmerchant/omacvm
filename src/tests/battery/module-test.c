/* The battery module in user space (src/tests/battery.sh): the real
 * omacvm-battery.c on a small stand-in for the kernel (linux/kernel.h here).
 *   module-test            the checks below
 *   module-test LINE       write LINE to the state file, print BAT0 as sysfs
 *                          would (one "name=value" or "name=ENODATA" a line) */
#include "../../battery/guest/module/omacvm-battery.c"

int omb_test_registered, omb_test_changed;
static int failed;

static void expect(const char *what, bool ok)
{
	printf("%s %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok)
		failed = 1;
}

static ssize_t write_line(const char *line)
{
	return state_store(NULL, NULL, line, strlen(line));
}

/* The property's value, or INT_MIN + error for an error. */
static int prop(enum power_supply_property p)
{
	union power_supply_propval v = { 0 };
	int error = omb_bat_get_property(omb_bat, p, &v);

	return error ? INT_MIN - error : v.intval;
}
#define NODATA (INT_MIN + ENODATA)

static const char *show(void)
{
	static char buf[PAGE_SIZE];

	state_show(NULL, NULL, buf);
	return buf;
}

static const struct { const char *name; enum power_supply_property p; } props[] = {
	{ "status", POWER_SUPPLY_PROP_STATUS },
	{ "capacity", POWER_SUPPLY_PROP_CAPACITY },
	{ "current_now", POWER_SUPPLY_PROP_CURRENT_NOW },
	{ "power_now", POWER_SUPPLY_PROP_POWER_NOW },
	{ "voltage_now", POWER_SUPPLY_PROP_VOLTAGE_NOW },
	{ "charge_now", POWER_SUPPLY_PROP_CHARGE_NOW },
	{ "time_to_empty_now", POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW },
	{ "time_to_empty_avg", POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG },
	{ "time_to_full_now", POWER_SUPPLY_PROP_TIME_TO_FULL_NOW },
	{ "charge_control_end_threshold", POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD },
};

static int print_line(const char *line)
{
	size_t i;
	ssize_t r;

	omb_test_init();
	r = write_line(line);
	if (r < 0) {
		printf("rejected=%zd\n", -r);
		return 0;
	}
	if (!omb_bat) {
		printf("present=0\n");
		return 0;
	}
	for (i = 0; i < ARRAY_SIZE(props); i++) {
		int v = prop(props[i].p);

		if (v == NODATA)
			printf("%s=ENODATA\n", props[i].name);
		else
			printf("%s=%d\n", props[i].name, v);
	}
	return 0;
}

int main(int argc, char **argv)
{
	const char *old = "present=1 status=discharging capacity=84 ac=0 time_to_empty=54660 time_to_full=-1 charge_limit=-1 charge_now=6818000 charge_full=8594000 charge_full_design=8579000 voltage_now=12290000 cycle_count=98\n";
	char line[512], again[PAGE_SIZE];
	int changed;

	if (argc == 2)
		return print_line(argv[1]);

	expect("version 1.1.0", !strcmp(omb_test_version, "1.1.0"));
	expect("init", omb_test_init() == 0 && omb_test_registered == 1);

	/* A 1.0.0 agent's line: taken; no current, no power. */
	expect("a line without current_now/power_now is taken", write_line(old) == (ssize_t)strlen(old));
	expect("BAT0 registered", omb_bat && omb_test_registered == 2);
	expect("no current: current_now ENODATA", prop(POWER_SUPPLY_PROP_CURRENT_NOW) == NODATA);
	expect("no power: power_now ENODATA", prop(POWER_SUPPLY_PROP_POWER_NOW) == NODATA);
	expect("no limit in macOS: end threshold 100", prop(POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD) == 100);
	expect("time_to_empty_now = avg", prop(POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW) == 54660 &&
	       prop(POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG) == 54660);
	expect("time_to_full_now ENODATA", prop(POWER_SUPPLY_PROP_TIME_TO_FULL_NOW) == NODATA);
	expect("state file: no current_now/power_now words", !strstr(show(), "current_now") && !strstr(show(), "power_now"));

	/* Discharging at 573 mA, 7.04 W. */
	snprintf(line, sizeof(line), "%.*s current_now=-573000 power_now=7042170\n", (int)strlen(old) - 1, old);
	changed = omb_test_changed;
	expect("current_now and power_now are taken", write_line(line) == (ssize_t)strlen(line));
	expect("a new current alone tells UPower (power_supply_changed)", omb_test_changed == changed + 1);
	expect("discharging: current_now -573000 µA", prop(POWER_SUPPLY_PROP_CURRENT_NOW) == -573000);
	expect("power_now 7042170 µW", prop(POWER_SUPPLY_PROP_POWER_NOW) == 7042170);
	expect("state file ends with current_now and power_now",
	       strstr(show(), " cycle_count=98 current_now=-573000 power_now=7042170\n") != NULL);
	strcpy(again, show());
	changed = omb_test_changed;
	expect("the state file's line is taken back as it is", write_line(again) == (ssize_t)strlen(again) &&
	       !strcmp(show(), again) && omb_test_changed == changed);
	write_line("present=1 status=discharging capacity=84 ac=0 current_now=573000\n");
	expect("discharging with a positive current: below 0 all the same", prop(POWER_SUPPLY_PROP_CURRENT_NOW) == -573000);
	expect("power_now left out: ENODATA", prop(POWER_SUPPLY_PROP_POWER_NOW) == NODATA);

	/* Charging, and on the charger with the battery helping. */
	write_line("present=1 status=charging capacity=50 ac=1 current_now=2100000 power_now=25000000 charge_limit=80\n");
	expect("charging: current_now above 0", prop(POWER_SUPPLY_PROP_CURRENT_NOW) == 2100000);
	expect("the limit set in macOS: 80", prop(POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD) == 80);
	write_line("present=1 status=not-charging capacity=80 ac=1 current_now=-120000 power_now=1400000\n");
	expect("not charging with a negative current: never below 0 (UPower would say discharging)",
	       prop(POWER_SUPPLY_PROP_CURRENT_NOW) == 120000);
	write_line("present=1 status=charging capacity=50 ac=1 current_now=-50000\n");
	expect("charging with a negative current: never below 0", prop(POWER_SUPPLY_PROP_CURRENT_NOW) == 50000);
	write_line("present=1 status=full capacity=100 ac=1 current_now=0 power_now=0\n");
	expect("full: current 0, power 0", prop(POWER_SUPPLY_PROP_CURRENT_NOW) == 0 && prop(POWER_SUPPLY_PROP_POWER_NOW) == 0);

	/* Bad lines go whole; the state stays. */
	strcpy(again, show());
	expect("current_now=INT_MIN refused", write_line("present=1 status=discharging capacity=84 ac=0 current_now=-2147483648\n") == -EINVAL);
	expect("current_now past int refused", write_line("present=1 status=discharging capacity=84 ac=0 current_now=-2147483649\n") < 0);
	expect("current_now=abc refused", write_line("present=1 status=discharging capacity=84 ac=0 current_now=abc\n") == -EINVAL);
	expect("power_now=-2 refused", write_line("present=1 status=discharging capacity=84 ac=0 power_now=-2\n") == -EINVAL);
	expect("an unknown word refused", write_line("present=1 status=discharging capacity=84 ac=0 energy_now=1\n") == -EINVAL);
	expect("after refused lines the state is as before", !strcmp(show(), again));
	expect("power_now=-1 is no power", write_line("present=1 status=discharging capacity=84 ac=0 power_now=-1 current_now=-1\n") > 0 &&
	       prop(POWER_SUPPLY_PROP_POWER_NOW) == NODATA && prop(POWER_SUPPLY_PROP_CURRENT_NOW) == -1);

	/* The Mac goes away: the agent's unknown line drops current and power. */
	write_line("present=1 status=unknown capacity=84 ac=0 time_to_empty=-1 time_to_full=-1 charge_limit=-1 charge_now=-1 charge_full=-1 charge_full_design=-1 voltage_now=-1 cycle_count=-1\n");
	expect("unknown: current_now and power_now ENODATA", prop(POWER_SUPPLY_PROP_CURRENT_NOW) == NODATA &&
	       prop(POWER_SUPPLY_PROP_POWER_NOW) == NODATA);
	write_line("present=0 ac=1\n");
	expect("no battery: BAT0 goes", !omb_bat && omb_test_registered == 1);
	omb_test_exit();
	expect("exit unregisters ADP0", omb_test_registered == 0);

	printf(failed ? "module: FAILED\n" : "module: all passed\n");
	return failed;
}
