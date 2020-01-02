cfg_pamac = configuration_data()
cfg_pamac.set('DATADIR', join_paths(get_option('prefix'),get_option('datadir')))
cfg_pamac.set('PKGDATADIR', join_paths(get_option('prefix'),get_option('datadir'),'pamac'))
cfg_pamac.set('GETTEXT_PACKAGE', 'pamac')
cfg_pamac.set('RELEASE_NAME', 'pamac')
cfg_pamac.set('PREFIX', get_option('prefix'))
cfg_pamac.set('VERSION', '7.1.2')
cfg_pamac.set('TESTSRCDIR', meson.source_root())

cfgfile_1 = configure_file(
	input: 'Config.vala.base',
	output: 'Config.vala',
	configuration: cfg_pamac)

pamac_deps = [atk_dep]
pamac_deps += [cairo_dep]
pamac_deps += [gdk_3_0_dep]
pamac_deps += [gdk_pixbuf_2_0_dep]
pamac_deps += [gio_2_0_dep]
pamac_deps += [glib_2_0_dep]
pamac_deps += [gobject_2_0_dep]
pamac_deps += [gtk_3_0_dep]
pamac_deps += [json_glib_1_0_dep]
pamac_deps += [libalpm_dep]
pamac_deps += [libsoup_2_4_dep]
pamac_deps += [pango_dep]
pamac_deps += [vte_2_91_dep]
pamac_deps += [x11_dep]
pamac_sources = [cfgfile_1]
pamac_sources += ['alpm_config.vala']
pamac_sources += ['aur.vala']
pamac_sources += ['choose_ignorepkgs_dialog.vala']
pamac_sources += ['choose_provider_dialog.vala']
pamac_sources += ['common.vala']
pamac_sources += ['mirrors_config.vala']
pamac_sources += ['package.vala']
pamac_sources += ['pamac_config.vala']
pamac_sources += ['preferences_dialog.vala']
pamac_sources += ['progress_box.vala']
pamac_sources += ['transaction.vala']
pamac_sources += ['transaction_sum_dialog.vala']
pamac_sources += [pamac_transaction_gresource_xml_file_c]
pamac_vala_args = ['--pkg','posix']
pamac_vala_args += ['--vapidir='+join_paths(meson.source_root(),'src/vapis')]
pamac_vala_args += ['--gresources='+join_paths(meson.source_root(),'data/pamac.transaction.gresource.xml')]
pamac_c_args = []
if ENABLE_UPDATE_ICON
  pamac_vala_args += ['-D', 'ENABLE_UPDATE_ICON']
  pamac_c_args += ['-DENABLE_UPDATE_ICON']
endif
if ENABLE_HAMBURGER
  pamac_vala_args += ['-D', 'ENABLE_HAMBURGER']
  pamac_c_args += ['-DENABLE_HAMBURGER']
endif
if KDE_TRAY
  pamac_vala_args += ['-D', 'KDE_TRAY']
  pamac_c_args += ['-DKDE_TRAY']
endif
if DISABLE_AUR
  pamac_vala_args += ['-D', 'DISABLE_AUR']
  pamac_c_args += ['-DDISABLE_AUR']
endif
pamac_deps += [meson.get_compiler('c').find_library('m', required : false)]
pamac_link_args = ['-rdynamic']

Pamac_library = shared_library('Pamac', pamac_sources,
    vala_gir: 'Pamac-1.0.gir',
    dependencies: pamac_deps,
    vala_args: pamac_vala_args,
    c_args: pamac_c_args,
    link_args: pamac_link_args,
    version: '7.1.2',
    soversion: '7',
    install: true,
    install_dir: [true, true, true, true])

g_ir_compiler = find_program('g-ir-compiler')
custom_target('Pamac typelib', command: [g_ir_compiler, '--shared-library=libPamac', '--output', '@OUTPUT@',  join_paths(meson.current_build_dir(), 'Pamac-1.0.gir')],
    output: 'Pamac-1.0.typelib',
    depends: Pamac_library,
    install: true,
    install_dir: join_paths(get_option('libdir'), 'girepository-1.0'))

pamac_requires = []
pamac_requires += ['atk']
pamac_requires += ['cairo']
pamac_requires += ['gdk-3.0']
pamac_requires += ['gdk-pixbuf-2.0']
pamac_requires += ['gio-2.0']
pamac_requires += ['glib-2.0']
pamac_requires += ['gobject-2.0']
pamac_requires += ['gtk+-3.0']
pamac_requires += ['json-glib-1.0']
pamac_requires += ['libalpm']
pamac_requires += ['libsoup-2.4']
pamac_requires += ['pango']
pamac_requires += ['vte-2.91']
pamac_requires += ['x11']
pkg_mod = import('pkgconfig')
pkg_mod.generate(libraries : Pamac_library,
	version : '7.1.2',
	name : 'Pamac',
	filebase : 'Pamac',
	description : 'Pamac',
	requires : pamac_requires)

install_data(join_paths(meson.current_source_dir(),'Pamac.deps'),install_dir: join_paths(get_option('prefix'),'share','vala','vapi'))
