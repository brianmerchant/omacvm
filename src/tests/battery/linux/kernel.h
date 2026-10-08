/* Just enough of the kernel for omacvm-battery.c in user space
 * (src/tests/battery.sh): parse, properties, the state file. */
#ifndef OMB_SHIM_H
#define OMB_SHIM_H
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#ifndef ENODATA
#define ENODATA 61
#endif
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define GFP_KERNEL 0
#define __init
#define __exit
#define module_init(f) int (*omb_test_init)(void) = f
#define module_exit(f) void (*omb_test_exit)(void) = f
#define MODULE_AUTHOR(s)
#define MODULE_DESCRIPTION(s)
#define MODULE_LICENSE(s)
#define MODULE_VERSION(s) const char *omb_test_version = s
#define PAGE_SIZE 4096

struct mutex { int held; };
#define DEFINE_MUTEX(m) struct mutex m = { 0 }
static inline void mutex_lock(struct mutex *m) { if (m->held) abort(); m->held = 1; }
static inline void mutex_unlock(struct mutex *m) { if (!m->held) abort(); m->held = 0; }

static inline char *kstrndup(const char *s, size_t n, int gfp) { (void)gfp; return strndup(s, n); }
static inline void kfree(const void *p) { free((void *)p); }

/* The kernel's: base 10 only here; a trailing newline is allowed. */
static inline int kstrtoint(const char *s, unsigned int base, int *res)
{
	char *end;
	long long v;

	if (!*s || *s == ' ')
		return -EINVAL;
	errno = 0;
	v = strtoll(s, &end, base);
	if (*end == '\n')
		end++;
	if (*end || errno)
		return -EINVAL;
	if (v < INT_MIN || v > INT_MAX)
		return -ERANGE;
	*res = (int)v;
	return 0;
}

static inline int kstrtobool(const char *s, bool *res)
{
	switch (s[0]) {
	case 'y': case 'Y': case 't': case 'T': case '1':
		*res = true; return 0;
	case 'n': case 'N': case 'f': case 'F': case '0':
		*res = false; return 0;
	}
	return -EINVAL;
}

static inline int sysfs_emit_at(char *buf, int at, const char *fmt, ...)
{
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(buf + at, PAGE_SIZE - at, fmt, ap);
	va_end(ap);
	return n;
}
#define sysfs_emit(buf, ...) sysfs_emit_at(buf, 0, __VA_ARGS__)

struct device { int unused; };
struct platform_device { struct device dev; };
struct device_attribute {
	ssize_t (*show)(struct device *, struct device_attribute *, char *);
	ssize_t (*store)(struct device *, struct device_attribute *, const char *, size_t);
};
#define DEVICE_ATTR_ADMIN_RW(name) \
	struct device_attribute dev_attr_##name = { name##_show, name##_store }

#define IS_ERR(p) ((unsigned long)(p) >= (unsigned long)-4095)
#define PTR_ERR(p) ((long)(p))

enum power_supply_property {
	POWER_SUPPLY_PROP_STATUS, POWER_SUPPLY_PROP_PRESENT, POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_CAPACITY, POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG,
	POWER_SUPPLY_PROP_TIME_TO_FULL_AVG, POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW,
	POWER_SUPPLY_PROP_TIME_TO_FULL_NOW, POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_POWER_NOW, POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,
	POWER_SUPPLY_PROP_CHARGE_NOW, POWER_SUPPLY_PROP_CHARGE_FULL,
	POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN, POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CYCLE_COUNT, POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_MANUFACTURER, POWER_SUPPLY_PROP_MODEL_NAME,
};
enum {
	POWER_SUPPLY_STATUS_UNKNOWN, POWER_SUPPLY_STATUS_CHARGING,
	POWER_SUPPLY_STATUS_DISCHARGING, POWER_SUPPLY_STATUS_NOT_CHARGING,
	POWER_SUPPLY_STATUS_FULL,
};
enum { POWER_SUPPLY_TYPE_BATTERY = 1, POWER_SUPPLY_TYPE_MAINS = 3 };
enum { POWER_SUPPLY_TECHNOLOGY_LION = 2 };
union power_supply_propval { int intval; const char *strval; };
struct power_supply { int registered; };
struct power_supply_config { int unused; };
struct power_supply_desc {
	const char *name;
	int type;
	enum power_supply_property *properties;
	size_t num_properties;
	int (*get_property)(struct power_supply *, enum power_supply_property,
			    union power_supply_propval *);
};

/* What the test watches: registrations and change notifications. */
extern int omb_test_registered, omb_test_changed;
static inline struct platform_device *platform_device_register_simple(const char *n, int id, void *r, int c)
{
	static struct platform_device pdev;
	(void)n; (void)id; (void)r; (void)c;
	return &pdev;
}
static inline void platform_device_unregister(struct platform_device *p) { (void)p; }
static inline int device_create_file(struct device *d, struct device_attribute *a) { (void)d; (void)a; return 0; }
static inline void device_remove_file(struct device *d, struct device_attribute *a) { (void)d; (void)a; }
static inline struct power_supply *power_supply_register(struct device *d, const struct power_supply_desc *desc,
							 struct power_supply_config *c)
{
	struct power_supply *p = calloc(1, sizeof(*p));
	(void)d; (void)desc; (void)c;
	omb_test_registered++;
	return p;
}
static inline void power_supply_unregister(struct power_supply *p) { omb_test_registered--; free(p); }
static inline void power_supply_changed(struct power_supply *p) { (void)p; omb_test_changed++; }
#endif
