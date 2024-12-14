DESTDIR=
PREFIX=/usr
REL=dellps-proxmox-$(VERSION)

export PERLDIR=${PREFIX}/share/perl5

all:
	@echo "The only useful target is 'deb'"

deb:
	dh_clean
	debuild -us -uc -i -b

install:
	install -D -m 0644 ./DELLPSPlugin.pm ${DESTDIR}$(PERLDIR)/PVE/Storage/Custom/DELLPSPlugin.pm
	install -D -m 0644 ./DELLPS/DellPS.pm ${DESTDIR}$(PERLDIR)/DELLPS/DellPS.pm
	install -D -m 0644 ./DELLPS/PluginHelper.pm ${DESTDIR}$(PERLDIR)/DELLPS/PluginHelper.pm

ifndef VERSION
debrelease:
	$(error environment variable VERSION is not set)
else
debrelease:
	head -n1 debian/changelog | grep -q "$$( echo '$(VERSION)' | sed -e 's/-rc/~rc/' )"
	grep 'PLUGIN_VERSION' DELLPSPlugin.pm | grep -q '$(VERSION)'
	dh_clean
	ln -s . $(REL) || true
	tar --owner=0 --group=0 -czvf $(REL).tar.gz \
		$(REL)/Makefile \
		$(REL)/README.md \
		$(REL)/CHANGELOG.md \
		$(REL)/DELLPSPlugin.pm \
		$(REL)/DELLPS/DellPS.pm \
		$(REL)/DELLPS/PluginHelper.pm \
		$(REL)/debian
	if test -L "$(REL)"; then rm $(REL); fi
endif
