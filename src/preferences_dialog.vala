/*
 *  pamac-vala
 *
 *  Copyright (C) 2017-2019 Chris Cromer <cromer@cromnix.org>
 *  Copyright (C) 2015-2017 Guillaume Benoit <guillaume@manjaro.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a get of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

namespace Pamac {

	[GtkTemplate (ui = "/org/pamac/preferences/interface/preferences_dialog.ui")]
	class PreferencesDialog : Gtk.Dialog {

		[GtkChild]
		unowned Gtk.Switch remove_unrequired_deps_button;
		[GtkChild]
		unowned Gtk.Switch update_files_db_button;
		[GtkChild]
		unowned Gtk.Switch check_space_button;
		[GtkChild]
		unowned Gtk.Switch check_updates_button;
		[GtkChild]
		unowned Gtk.Label refresh_period_label;
		[GtkChild]
		unowned Gtk.SpinButton refresh_period_spin_button;
		[GtkChild]
		unowned Gtk.CheckButton no_update_hide_icon_checkbutton;
		[GtkChild]
		unowned Gtk.Box ignorepkgs_box;
		[GtkChild]
		unowned Gtk.TreeView ignorepkgs_treeview;
		[GtkChild]
		unowned Gtk.Box mirrors_config_box;
		[GtkChild]
		unowned Gtk.ComboBoxText mirrors_country_comboboxtext;
		[GtkChild]
		unowned Gtk.ComboBoxText mirrors_list_generation_method_comboboxtext;
		[GtkChild]
		unowned Gtk.Button generate_mirrors_list_button;
#if DISABLE_AUR
		[GtkChild]
		unowned Gtk.Stack stack;
		[GtkChild]
		unowned Gtk.Box aur_config_box;
#else
		[GtkChild]
		unowned Gtk.Switch enable_aur_button;
		[GtkChild]
		unowned Gtk.CheckButton search_aur_checkbutton;
		[GtkChild]
		unowned Gtk.Label aur_build_dir_label;
		[GtkChild]
		unowned Gtk.FileChooserButton aur_build_dir_file_chooser;
		[GtkChild]
		unowned Gtk.CheckButton check_aur_updates_checkbutton;
#endif
		[GtkChild]
		unowned Gtk.Label cache_keep_nb_label;
		[GtkChild]
		unowned Gtk.SpinButton cache_keep_nb_spin_button;
		[GtkChild]
		unowned Gtk.CheckButton cache_only_uninstalled_checkbutton;
		[GtkChild]
		unowned Gtk.ColorButton terminal_background;
		[GtkChild]
		unowned Gtk.ColorButton terminal_foreground;
		[GtkChild]
		unowned Gtk.FontButton terminal_font;

		Gtk.ListStore ignorepkgs_liststore;
		Transaction transaction;
		uint64 previous_refresh_period;
		string[] countries;

		public PreferencesDialog (Transaction transaction) {
			Object (transient_for: transaction.application_window, use_header_bar: 1);

			this.transaction = transaction;
			refresh_period_label.set_markup (dgettext (null, "How often to check for updates, value in hours") +":");
			cache_keep_nb_label.set_markup (dgettext (null, "Number of versions of each package to keep in the cache") +":");
#if DISABLE_AUR
			stack.remove (aur_config_box);
#else
			aur_build_dir_label.set_markup (dgettext (null, "Build directory") +":");
#endif
			remove_unrequired_deps_button.active = transaction.recurse;
			update_files_db_button.active = transaction.update_files_db;
			check_space_button.active = transaction.get_checkspace ();
			if (transaction.refresh_period == 0) {
				check_updates_button.active = false;
				refresh_period_label.sensitive = false;
				// set default value
				refresh_period_spin_button.value = 6;
				previous_refresh_period = 6;
				refresh_period_spin_button.sensitive = false;
				no_update_hide_icon_checkbutton.sensitive = false;
				ignorepkgs_box.sensitive = false;
			} else {
				check_updates_button.active = true;
				refresh_period_spin_button.value = transaction.refresh_period;
				previous_refresh_period = transaction.refresh_period;
			}
			no_update_hide_icon_checkbutton.active = transaction.no_update_hide_icon;
			cache_keep_nb_spin_button.value = transaction.keep_num_pkgs;
			cache_only_uninstalled_checkbutton.active = transaction.rm_only_uninstalled;

			// Set up terminal
			terminal_background.use_alpha = false;
			terminal_foreground.use_alpha = false;
			Gdk.RGBA rgba = Gdk.RGBA ();
			bool tmp = rgba.parse (transaction.terminal_background);
			terminal_background.rgba = rgba;
			tmp = rgba.parse (transaction.terminal_foreground);
			terminal_foreground.rgba = rgba;
			terminal_font.set_font(transaction.terminal_font);

			// populate ignorepkgs_liststore
			ignorepkgs_liststore = new Gtk.ListStore (1, typeof (string));
			ignorepkgs_treeview.set_model (ignorepkgs_liststore);
			foreach (unowned string ignorepkg in transaction.get_ignorepkgs ()) {
				ignorepkgs_liststore.insert_with_values (null, -1, 0, ignorepkg);
			}
			remove_unrequired_deps_button.state_set.connect (on_remove_unrequired_deps_button_state_set);
			update_files_db_button.state_set.connect (on_update_files_db_button_state_set);
			check_space_button.state_set.connect (on_check_space_button_state_set);
			transaction.write_alpm_config_finished.connect (on_write_alpm_config_finished);
			check_updates_button.state_set.connect (on_check_updates_button_state_set);
			refresh_period_spin_button.value_changed.connect (on_refresh_period_spin_button_value_changed);
			no_update_hide_icon_checkbutton.toggled.connect (on_no_update_hide_icon_checkbutton_toggled);
			cache_keep_nb_spin_button.value_changed.connect (on_cache_keep_nb_spin_button_value_changed);
			cache_only_uninstalled_checkbutton.toggled.connect (on_cache_only_uninstalled_checkbutton_toggled);
			terminal_background.color_set.connect (on_select_background);
			terminal_foreground.color_set.connect (on_select_foreground);
			terminal_font.font_set.connect (on_select_font);

			AlpmPackage pkg = transaction.find_installed_satisfier ("pacman-mirrors");
			if (pkg.name == "") {
				mirrors_config_box.visible = false;
			} else {
				var mirrors_config = new MirrorsConfig ("/etc/pacman-mirrors.conf");
				mirrors_country_comboboxtext.append_text (dgettext (null, "Worldwide"));
				mirrors_country_comboboxtext.active = 0;
				countries = transaction.get_mirrors_countries ();
				int index = 1;
				foreach (unowned string country in countries) {
					mirrors_country_comboboxtext.append_text (country);
					if (country == mirrors_config.choosen_country) {
						mirrors_country_comboboxtext.active = index;
					}
					index += 1;
				}
				mirrors_list_generation_method_comboboxtext.append_text (dgettext (null, "Speed"));
				mirrors_list_generation_method_comboboxtext.append_text (dgettext (null, "Random"));
				if (mirrors_config.choosen_generation_method == "rank") {
					mirrors_list_generation_method_comboboxtext.active = 0;
				} else {
					mirrors_list_generation_method_comboboxtext.active = 1;
				}
				mirrors_country_comboboxtext.changed.connect (on_mirrors_country_comboboxtext_changed);
				mirrors_list_generation_method_comboboxtext.changed.connect (on_mirrors_list_generation_method_comboboxtext_changed);
				transaction.write_mirrors_config_finished.connect (on_write_mirrors_config_finished);
			}

#if DISABLE_AUR
#else
			enable_aur_button.active = transaction.enable_aur;
			search_aur_checkbutton.active = transaction.search_aur;
			search_aur_checkbutton.sensitive = transaction.enable_aur;
			aur_build_dir_label.sensitive = transaction.enable_aur;
			aur_build_dir_file_chooser.sensitive = transaction.enable_aur;
			aur_build_dir_file_chooser.set_filename (transaction.aur_build_dir);
			// add /tmp choice always visible
			try {
				aur_build_dir_file_chooser.add_shortcut_folder ("/tmp");
			} catch (GLib.Error e) {
				stderr.printf ("%s\n", e.message);
			}
			check_aur_updates_checkbutton.active = transaction.check_aur_updates;
			check_aur_updates_checkbutton.sensitive = transaction.enable_aur;
			enable_aur_button.state_set.connect (on_enable_aur_button_state_set);
			search_aur_checkbutton.toggled.connect (on_search_aur_checkbutton_toggled);
			aur_build_dir_file_chooser.file_set.connect (on_aur_build_dir_set);
			check_aur_updates_checkbutton.toggled.connect (on_check_aur_updates_checkbutton_toggled);
#endif
		}

		bool on_remove_unrequired_deps_button_state_set (bool new_state) {
			var settings = new Settings ("org.pamac.main");
			settings.set_boolean ("remove-unrequired-deps", new_state);
			config_changed();
			transaction.start_save_pamac_config ();
			return true;
		}

		bool on_update_files_db_button_state_set (bool new_state) {
			var settings = new Settings ("org.pamac.main");
			settings.set_boolean ("update-files-db", new_state);
			config_changed();
			transaction.start_save_pamac_config ();
			return true;
		}

		bool on_check_updates_button_state_set (bool new_state) {
			var settings = new Settings ("org.pamac.main");
			refresh_period_label.sensitive = new_state;
			refresh_period_spin_button.sensitive = new_state;
			no_update_hide_icon_checkbutton.sensitive = new_state;
			ignorepkgs_box.sensitive = new_state;
			if (new_state) {
				settings.set_uint64 ("refresh-period", previous_refresh_period);
			} else {
				settings.set_uint64 ("refresh-period", 0);
			}
			config_changed();
			transaction.start_save_pamac_config ();
			return true;
		}

		void on_refresh_period_spin_button_value_changed () {
			var settings = new Settings ("org.pamac.main");
			settings.set_uint64 ("refresh-period", refresh_period_spin_button.get_value_as_int ());
			config_changed();
			transaction.start_save_pamac_config ();
		}

		void on_cache_keep_nb_spin_button_value_changed () {
			var settings = new Settings ("org.pamac.main");
			settings.set_uint64 ("keep-num-packages", cache_keep_nb_spin_button.get_value_as_int ());
			config_changed();
			transaction.start_save_pamac_config ();
		}

		void on_cache_only_uninstalled_checkbutton_toggled () {
			var settings = new Settings ("org.pamac.main");
			settings.set_boolean ("only-rm-uninstalled", cache_only_uninstalled_checkbutton.active);
			config_changed();
			transaction.start_save_pamac_config ();
		}

		void on_no_update_hide_icon_checkbutton_toggled () {
			var settings = new Settings ("org.pamac.main");
			settings.set_boolean ("no-update-hide-icon", no_update_hide_icon_checkbutton.active);
			config_changed();
			transaction.start_save_pamac_config ();
		}

		void on_select_background () {
			var settings = new Settings ("org.pamac.main");
			settings.set_string ("background-color", terminal_background.rgba.to_string ());
			config_changed();
			transaction.start_save_pamac_config ();
			transaction.update_terminal_background (terminal_background.rgba.to_string ());
		}

		void on_select_foreground () {
			var settings = new Settings ("org.pamac.main");
			settings.set_string ("foreground-color", terminal_foreground.rgba.to_string ());
			config_changed();
			transaction.start_save_pamac_config ();
			transaction.update_terminal_foreground (terminal_foreground.rgba.to_string ());
		}

		void on_select_font () {
			var settings = new Settings ("org.pamac.main");
			settings.set_string ("terminal-font", terminal_font.get_font ());
			config_changed();
			transaction.start_save_pamac_config ();
			transaction.update_terminal_font (terminal_font.get_font ());
		}

#if DISABLE_AUR
#else
		bool on_enable_aur_button_state_set (bool new_state) {
			var settings = new Settings ("org.pamac.aur");
			settings.set_boolean ("enable-aur", new_state);
			config_changed();
			transaction.start_save_pamac_config ();
			return true;
		}

		void on_search_aur_checkbutton_toggled () {
			var settings = new Settings ("org.pamac.aur");
			settings.set_boolean ("search-in-aur", search_aur_checkbutton.active);
			config_changed();
			transaction.start_save_pamac_config ();
		}

		void on_aur_build_dir_set () {
			var settings = new Settings ("org.pamac.aur");
			settings.set_string ("build-directory", aur_build_dir_file_chooser.get_filename ());
			config_changed();
			transaction.start_save_pamac_config ();
		}

		void on_check_aur_updates_checkbutton_toggled () {
			var settings = new Settings ("org.pamac.aur");
			settings.set_boolean ("check-aur-updates", check_aur_updates_checkbutton.active);
			config_changed();
			transaction.start_save_pamac_config ();
		}
#endif

		void config_changed() {
			transaction.config_changed();
			remove_unrequired_deps_button.state = transaction.recurse;
			update_files_db_button.state = transaction.update_files_db;
			if (transaction.refresh_period == 0) {
				check_updates_button.state = false;
				refresh_period_label.sensitive = false;
				refresh_period_spin_button.sensitive = false;
				no_update_hide_icon_checkbutton.sensitive = false;
				ignorepkgs_box.sensitive = false;
			} else {
				check_updates_button.state = true;
				refresh_period_label.sensitive = true;
				refresh_period_spin_button.value = transaction.refresh_period;
				previous_refresh_period = transaction.refresh_period;
				refresh_period_spin_button.sensitive = true;
				no_update_hide_icon_checkbutton.sensitive = true;
				ignorepkgs_box.sensitive = true;
			}
			no_update_hide_icon_checkbutton.active = transaction.no_update_hide_icon;
#if DISABLE_AUR
#else
			enable_aur_button.state = transaction.enable_aur;
			search_aur_checkbutton.active = transaction.search_aur;
			search_aur_checkbutton.sensitive = transaction.enable_aur;
			aur_build_dir_label.sensitive = transaction.enable_aur;
			aur_build_dir_file_chooser.sensitive = transaction.enable_aur;
			check_aur_updates_checkbutton.active = transaction.check_aur_updates;
			check_aur_updates_checkbutton.sensitive = transaction.enable_aur;
#endif
		}

		bool on_check_space_button_state_set (bool new_state) {
			var new_alpm_conf = new HashTable<string,Variant> (str_hash, str_equal);
			new_alpm_conf.insert ("CheckSpace", new Variant.boolean (new_state));
			check_space_button.state = new_state;
			transaction.start_write_alpm_config (new_alpm_conf);
			return true;
		}

		[GtkCallback]
		void on_add_ignorepkgs_button_clicked () {
			var choose_ignorepkgs_dialog = new ChooseIgnorepkgsDialog (this);
			this.get_window ().set_cursor (new Gdk.Cursor.for_display (Gdk.Display.get_default (), Gdk.CursorType.WATCH));
			while (Gtk.events_pending ()) {
				Gtk.main_iteration ();
			}
			transaction.get_installed_pkgs.begin ((obj, res) => {
				var pkgs = transaction.get_installed_pkgs.end (res);
				foreach (unowned AlpmPackage pkg in pkgs) {
					if (pkg.name in transaction.get_ignorepkgs ()) {
						choose_ignorepkgs_dialog.pkgs_list.insert_with_values (null, -1, 0, true, 1, pkg.name);
					} else {
						choose_ignorepkgs_dialog.pkgs_list.insert_with_values (null, -1, 0, false, 1, pkg.name);
					}
				}
				this.get_window ().set_cursor (null);
				if (choose_ignorepkgs_dialog.run () == Gtk.ResponseType.OK) {
					var ignorepkg_string = new StringBuilder ();
					choose_ignorepkgs_dialog.pkgs_list.foreach ((model, path, iter) => {
						GLib.Value val;
						// get value at column 0 to know if it is selected
						model.get_value (iter, 0, out val);
						if ((bool) val) {
							// get value at column 1 to get the pkg name
							model.get_value (iter, 1, out val);
							if (ignorepkg_string.len != 0) {
								ignorepkg_string.append (" ");
							}
							ignorepkg_string.append ((string) val);
						}
						return false;
					});
					var new_alpm_conf = new HashTable<string,Variant> (str_hash, str_equal);
					new_alpm_conf.insert ("IgnorePkg", new Variant.string (ignorepkg_string.str));
					transaction.start_write_alpm_config (new_alpm_conf);
				}
				choose_ignorepkgs_dialog.destroy ();
				while (Gtk.events_pending ()) {
					Gtk.main_iteration ();
				}
			});
		}

		[GtkCallback]
		void on_remove_ignorepkgs_button_clicked () {
			Gtk.TreeIter? iter;
			Gtk.TreeSelection selection = ignorepkgs_treeview.get_selection ();
			if (selection.get_selected (null, out iter)) {
				ignorepkgs_liststore.remove (ref iter);
				var ignorepkg_string = new StringBuilder ();
				ignorepkgs_liststore.foreach ((model, path, iter) => {
					GLib.Value name;
					model.get_value (iter, 0, out name);
					if (ignorepkg_string.len != 0) {
						ignorepkg_string.append (" ");
					}
					ignorepkg_string.append ((string) name);
					return false;
				});
				var new_alpm_conf = new HashTable<string,Variant> (str_hash, str_equal);
				new_alpm_conf.insert ("IgnorePkg", new Variant.string (ignorepkg_string.str));
				transaction.start_write_alpm_config (new_alpm_conf);
			}
		}

		void on_write_alpm_config_finished (bool checkspace) {
			check_space_button.state = checkspace;
			ignorepkgs_liststore.clear ();
			foreach (unowned string ignorepkg in transaction.get_ignorepkgs ()) {
				ignorepkgs_liststore.insert_with_values (null, -1, 0, ignorepkg);
			}
		}

		void on_mirrors_country_comboboxtext_changed () {
			var new_mirrors_conf = new HashTable<string,Variant> (str_hash, str_equal);
			var mirror_country = mirrors_country_comboboxtext.get_active_text ();
			if (mirror_country == dgettext (null, "Worldwide")) {
				mirror_country = "ALL";
			}
			new_mirrors_conf.insert ("OnlyCountry", new Variant.string (mirror_country) );
			transaction.start_write_mirrors_config (new_mirrors_conf);
		}

		void on_mirrors_list_generation_method_comboboxtext_changed () {
			var new_mirrors_conf = new HashTable<string,Variant> (str_hash, str_equal);
			if (mirrors_list_generation_method_comboboxtext.get_active_text () == dgettext (null, "Speed")){
				new_mirrors_conf.insert ("Method", new Variant.string ("rank"));
			} else {
				new_mirrors_conf.insert ("Method", new Variant.string ("random"));
			}
			transaction.start_write_mirrors_config (new_mirrors_conf);
		}

		void on_write_mirrors_config_finished (string choosen_country, string choosen_generation_method) {
			int index = 0;
			string choosen_country_ = dgettext (null, "Worldwide");
			if (choosen_country != "ALL") {
				choosen_country_ = choosen_country;
			}
			mirrors_country_comboboxtext.model.foreach ((model, path, iter) => {
				GLib.Value country;
				model.get_value (iter, 0, out country);
				if ((string) country == choosen_country_) {
					return true;
				}
				index += 1;
				return false;
			});
			mirrors_country_comboboxtext.active = index;
			if (choosen_generation_method == "rank") {
				mirrors_list_generation_method_comboboxtext.active = 0;
			} else {
				mirrors_list_generation_method_comboboxtext.active = 1;
			}
			generate_mirrors_list_button.get_style_context ().add_class (Gtk.STYLE_CLASS_SUGGESTED_ACTION);
		}

		[GtkCallback]
		void on_generate_mirrors_list_button_clicked () {
			transaction.start_generate_mirrors_list ();
			generate_mirrors_list_button.get_style_context ().remove_class (Gtk.STYLE_CLASS_SUGGESTED_ACTION);
		}

		[GtkCallback]
		void on_cache_clean_button_clicked () {
			transaction.clean_cache (transaction.keep_num_pkgs, transaction.rm_only_uninstalled);
		}
	}
}
