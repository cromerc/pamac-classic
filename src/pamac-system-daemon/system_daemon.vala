/*
 *  pamac-vala
 *
 *  Copyright (C) 2017-2019 Chris Cromer <cromer@cromnix.org>
 *  Copyright (C) 2014-2017 Guillaume Benoit <guillaume@manjaro.org>
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

Pamac.SystemDaemon system_daemon;
MainLoop loop;

public delegate void AlpmActionDelegate ();

[Compact]
public class AlpmAction {
	public unowned AlpmActionDelegate action_delegate;
	public AlpmAction (AlpmActionDelegate action_delegate) {
		this.action_delegate = action_delegate;
	}
	public void run () {
		action_delegate ();
	}
}

namespace Pamac {
	[DBus (name = "org.pamac.system")]
	public class SystemDaemon: Object {
		private AlpmConfig alpm_config;
		private Alpm.Handle? alpm_handle;
		private Alpm.Handle? files_handle;
		public Cond provider_cond;
		public Mutex provider_mutex;
		public int? choosen_provider;
		private bool refreshed;
		private bool force_refresh;
		private bool enable_downgrade;
#if DISABLE_AUR
#else
		private bool check_aur_updates;
		private bool aur_updates_checked;
#endif
		private HashTable<string,Variant> new_alpm_conf;
		private Alpm.TransFlag flags;
		private string[] to_install;
		private string[] to_remove;
		private string[] to_load;
#if DISABLE_AUR
#else
		private string[] to_build;
		private UpdateInfos[] to_build_infos;
		private GLib.List<string> aur_pkgbases_to_build;
		private GenericSet<string?> aur_desc_list;
		private GenericSet<string?> already_checked_aur_dep;
#endif
		private HashTable<string, string> to_install_as_dep;
#if DISABLE_AUR
#else
		private string aurdb_path;
#endif
		private string[] temporary_ignorepkgs;
#if DISABLE_AUR
#else
		private UpdateInfos[] aur_conflicts_to_remove;
#endif
		private ThreadPool<AlpmAction> thread_pool;
		private BusName lock_id;
#if DISABLE_AUR
#else
		private Json.Array aur_updates_results;
#endif
		private GLib.File lockfile;
		public ErrorInfos current_error;
		public Timer timer;
		public Cancellable cancellable;
		public Curl.Easy curl;
		private bool authorized;

		public signal void emit_event (uint primary_event, uint secondary_event, string[] details);
		public signal void emit_providers (string depend, string[] providers);
		public signal void emit_progress (uint progress, string pkgname, uint percent, uint n_targets, uint current_target);
		public signal void emit_download (string filename, uint64 xfered, uint64 total);
		public signal void emit_totaldownload (uint64 total);
		public signal void emit_log (uint level, string msg);
		public signal void set_pkgreason_finished ();
		public signal void refresh_finished (bool success);
		public signal void get_updates_finished (Updates updates);
		public signal void trans_prepare_finished (bool success);
		public signal void trans_commit_finished (bool success);
		public signal void get_authorization_finished (bool authorized);
#if DISABLE_AUR
		public signal void save_pamac_config_finished (bool recurse, uint64 refresh_period, bool no_update_hide_icon);
#else
		public signal void save_pamac_config_finished (bool recurse, uint64 refresh_period, bool no_update_hide_icon,
														bool enable_aur, bool search_aur, string aur_build_dir, bool check_aur_updates);
#endif
		public signal void write_alpm_config_finished (bool checkspace);
		public signal void write_mirrors_config_finished (string choosen_country, string choosen_generation_method);
		public signal void generate_mirrors_list_data (string line);
		public signal void generate_mirrors_list_finished ();

		public SystemDaemon () {
			alpm_config = new AlpmConfig ("/etc/pacman.conf");
#if DISABLE_AUR
#else
			aur_pkgbases_to_build = new GLib.List<string> ();
			aur_desc_list = new GenericSet<string?> (str_hash, str_equal);
			already_checked_aur_dep = new GenericSet<string?> (str_hash, str_equal);
#endif
			to_install_as_dep = new HashTable<string, string> (str_hash, str_equal);
#if DISABLE_AUR
#else
			aurdb_path = "/tmp/pamac-aur";
			aur_updates_results = new Json.Array ();
#endif
			timer = new Timer ();
			lock_id = new BusName ("");
			refresh_handle ();
			check_old_lock ();
			check_extern_lock ();
			Timeout.add (500, check_extern_lock);
			create_thread_pool ();
			cancellable = new Cancellable ();
			curl = new Curl.Easy ();
			authorized = false;
			refreshed = false;
		}

		public void set_environment_variables (HashTable<string,string> variables) throws DBusError, IOError {
			string[] keys = { "HTTP_USER_AGENT",
							"http_proxy",
							"https_proxy",
							"ftp_proxy",
							"socks_proxy",
							"no_proxy" };
			foreach (unowned string key in keys) {
				unowned string val;
				if (variables.lookup_extended (key, null, out val)) {
					Environment.set_variable (key, val, true);
				}
			}
		}

		public ErrorInfos get_current_error () throws DBusError, IOError {
			return current_error;
		}

		private void create_thread_pool () {
			// create a thread pool which will run alpm action one after one
			try {
				thread_pool = new ThreadPool<AlpmAction>.with_owned_data (
					// call alpm_action.run () on thread start
					(alpm_action) => {
						alpm_action.run ();
					},
					// only one thread created so alpm action will run one after one
					1,
					// no exclusive thread
					false
				);
			} catch (ThreadError e) {
				stderr.printf ("Thread Error %s\n", e.message);
			}
		}

		private void refresh_handle () {
			alpm_handle = alpm_config.get_handle ();
			if (alpm_handle == null) {
				current_error = ErrorInfos () {
					message = _("Failed to initialize alpm library")
				};
				trans_commit_finished (false);
				return;
			} else {
				alpm_handle.set_eventcb((Alpm.EventCallBack) cb_event, null);
				alpm_handle.set_progresscb((Alpm.ProgressCallBack) cb_progress, null);
				alpm_handle.set_questioncb((Alpm.QuestionCallBack) cb_question, null);
				alpm_handle.set_fetchcb((Alpm.FetchCallBack) cb_fetch, null);
				alpm_handle.set_dlcb((Alpm.DownloadCallBack) cb_download, null);
				alpm_handle.set_logcb((Alpm.LogCallBack) cb_log, null);
				lockfile = GLib.File.new_for_path (alpm_handle.lockfile);
				var pamac_config = new Pamac.Config ();
				if (pamac_config.update_files_db) {
					files_handle = alpm_config.get_handle (true);
				} else {
					files_handle = alpm_config.get_handle (false);
				}
				files_handle.set_eventcb((Alpm.EventCallBack) cb_event, null);
				files_handle.set_progresscb((Alpm.ProgressCallBack) cb_progress, null);
				files_handle.set_questioncb((Alpm.QuestionCallBack) cb_question, null);
				files_handle.set_fetchcb((Alpm.FetchCallBack) cb_fetch, null);
				files_handle.set_dlcb((Alpm.DownloadCallBack) cb_download, null);
				files_handle.set_logcb((Alpm.LogCallBack) cb_log, null);
			}
		}

		private void check_old_lock () {
			if (lockfile.query_exists ()) {
				int exit_status;
				string output;
				uint64 lockfile_time;
				try {
					// get lockfile modification time since epoch
					Process.spawn_command_line_sync ("stat -c %Y %s".printf (alpm_handle.lockfile),
													out output,
													null,
													out exit_status);
					if (exit_status == 0) {
						string[] splitted = output.split ("\n");
						if (splitted.length == 2) {
							if (uint64.try_parse (splitted[0], out lockfile_time)) {
								uint64 boot_time;
								// get boot time since epoch
								Process.spawn_command_line_sync ("cat /proc/stat",
																out output,
																null,
																out exit_status);
								if (exit_status == 0) {
									splitted = output.split ("\n");
									foreach (unowned string line in splitted) {
										if ("btime" in line) {
											string[] space_splitted = line.split (" ");
											if (space_splitted.length == 2) {
												if (uint64.try_parse (space_splitted[1], out boot_time)) {
													// check if lock file is older than boot time
													if (lockfile_time < boot_time) {
														// remove the unneeded lock file.
														try {
															lockfile.delete ();
														} catch (Error e) {
															stderr.printf ("Error: %s\n", e.message);
														}
														lock_id = new BusName ("");
													}
												}
											}
										}
									}
								}
							}
						}
					}
				} catch (SpawnError e) {
					stderr.printf ("Error: %s\n", e.message);
				}
			}
		}

		private bool check_extern_lock () {
			if (lock_id == "extern") {
				if (!lockfile.query_exists ()) {
					lock_id = new BusName ("");
					refresh_handle ();
				}
			} else {
				if (lockfile.query_exists ()) {
					if (lock_id == "") {
						// An extern lock appears
						lock_id = new BusName ("extern");
					}
				}
			}
			return true;
		}

		public string[] get_mirrors_countries () throws DBusError, IOError {
			string[] countries = {};
			try {
				string countries_str;
				int status;
				Process.spawn_command_line_sync ("pacman-mirrors -lq",
											out countries_str,
											null,
											out status);
				if (status == 0) {
					foreach (unowned string country in countries_str.split ("\n")) {
						countries += country;
					}
				}
			} catch (SpawnError e) {
				stderr.printf ("Error: %s\n", e.message);
			}
			return countries;
		}

		public bool get_lock (GLib.BusName sender) throws DBusError, IOError {
			if (lock_id == sender) {
				return true;
			} else if (lock_id == "") {
				lock_id = sender;
				return true;
			}
			return false;
		}

		public bool unlock (GLib.BusName sender) throws DBusError, IOError {
			if (lock_id == sender) {
				lock_id = new BusName ("");
				return true;
			}
			return false;
		}

		private async bool check_authorization (GLib.BusName sender) {
			if (lock_id != sender) {
				return false;
			}
			if (authorized) {
				return true;
			}
			SourceFunc callback = check_authorization.callback;
			try {
				Polkit.Authority authority = Polkit.Authority.get_sync ();
				Polkit.Subject subject = Polkit.SystemBusName.new (sender);
				authority.check_authorization.begin (
					subject,
					"org.pamac.commit",
					null,
					Polkit.CheckAuthorizationFlags.ALLOW_USER_INTERACTION,
					null,
					(obj, res) => {
						try {
							var result = authority.check_authorization.end (res);
							authorized = result.get_is_authorized ();
						} catch (GLib.Error e) {
							stderr.printf ("%s\n", e.message);
						}
						Idle.add ((owned) callback);
					}
				);
				yield;
			} catch (GLib.Error e) {
				stderr.printf ("%s\n", e.message);
			}
			if (!authorized) {
				current_error = ErrorInfos () {
					message = _("Authentication failed")
				};
			}
			return authorized;
		}

		public void start_get_authorization (GLib.BusName sender) throws DBusError, IOError {
			check_authorization.begin (sender, (obj, res) => {
				bool authorized = check_authorization.end (res);
				get_authorization_finished (authorized);
			});
		}

		public void start_save_pamac_config () throws DBusError, IOError {
				var pamac_config = new Pamac.Config ();
				pamac_config.reload ();
#if DISABLE_AUR
				save_pamac_config_finished (pamac_config.recurse, pamac_config.refresh_period, pamac_config.no_update_hide_icon);
#else
				save_pamac_config_finished (pamac_config.recurse, pamac_config.refresh_period, pamac_config.no_update_hide_icon,
											pamac_config.enable_aur, pamac_config.search_aur, pamac_config.aur_build_dir, pamac_config.check_aur_updates);
#endif
		}

		private void write_alpm_config () {
			alpm_config.write (new_alpm_conf);
			alpm_config.reload ();
			refresh_handle ();
			write_alpm_config_finished ((alpm_handle.checkspace == 1));
		}

		public void start_write_alpm_config (HashTable<string,Variant> new_alpm_conf_, GLib.BusName sender) throws DBusError, IOError {
			check_authorization.begin (sender, (obj, res) => {
				bool authorized = check_authorization.end (res);
				if (authorized ) {
					new_alpm_conf = new_alpm_conf_;
					try {
						thread_pool.add (new AlpmAction (write_alpm_config));
					} catch (ThreadError e) {
						stderr.printf ("Thread Error %s\n", e.message);
					}
				} else {
					write_alpm_config_finished ((alpm_handle.checkspace == 1));
				}
			});
		}

		private void generate_mirrors_list () {
			try {
				var process = new Subprocess.newv (
					{"pacman-mirrors", "-g"},
					SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
				var dis = new DataInputStream (process.get_stdout_pipe ());
				string? line;
				while ((line = dis.read_line ()) != null) {
					generate_mirrors_list_data (line);
				}
			} catch (Error e) {
				stderr.printf ("Error: %s\n", e.message);
			}
			alpm_config.reload ();
			refresh_handle ();
			generate_mirrors_list_finished ();
		}

		public void start_generate_mirrors_list (GLib.BusName sender) throws DBusError, IOError {
			check_authorization.begin (sender, (obj, res) => {
				bool authorized = check_authorization.end (res);
				if (authorized) {
					try {
						thread_pool.add (new AlpmAction (generate_mirrors_list));
					} catch (ThreadError e) {
						stderr.printf ("Thread Error %s\n", e.message);
					}
				}
			});
		}

		public void clean_cache (uint64 keep_nb, bool only_uninstalled, GLib.BusName sender) throws DBusError, IOError {
			check_authorization.begin (sender, (obj, res) => {
				bool authorized = check_authorization.end (res);
				if (authorized) {
					string[] commands = {"paccache", "--nocolor", "-rq"};
					commands += "-k%llu".printf (keep_nb);
					if (only_uninstalled) {
						commands += "-u";
					}
					try {
						new Subprocess.newv (
							commands,
							SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
					} catch (Error e) {
						stderr.printf ("Error: %s\n", e.message);
					}
				}
			});
		}

		public void start_write_mirrors_config (HashTable<string,Variant> new_mirrors_conf, GLib.BusName sender) throws DBusError, IOError {
			check_authorization.begin (sender, (obj, res) => {
				var mirrors_config = new MirrorsConfig ("/etc/pacman-mirrors.conf");
				bool authorized = check_authorization.end (res);
				if (authorized) {
					mirrors_config.write (new_mirrors_conf);
					mirrors_config.reload ();
				}
				write_mirrors_config_finished (mirrors_config.choosen_country, mirrors_config.choosen_generation_method);
			});
		}

		public void start_set_pkgreason (string pkgname, uint reason, GLib.BusName sender) throws DBusError, IOError {
			check_authorization.begin (sender, (obj, res) => {
				bool authorized = check_authorization.end (res);
				if (authorized) {
					unowned Alpm.Package? pkg = alpm_handle.localdb.get_pkg (pkgname);
					if (pkg != null) {
						// lock the database
						if (alpm_handle.trans_init (0) == 0) {
							pkg.reason = (Alpm.Package.Reason) reason;
							alpm_handle.trans_release ();
						}
					}
				}
				set_pkgreason_finished ();
			});
		}

		private bool update_dbs (Alpm.Handle handle, int force) {
			bool success = false;
			unowned Alpm.List<unowned Alpm.DB> syncdbs = handle.syncdbs;
			if (handle.update_dbs (syncdbs, force) >= 0) {
				// We should always succeed if at least one DB was upgraded - we may possibly
				// fail later with unresolved deps, but that should be rare, and would be expected
				success = true;
			} else {
				Alpm.Errno errnos = handle.errno ();
				current_error.errnos = (uint) errnos;
				if (errnos != 0) {
					// download error details are set in cb_fetch
					if (errnos != Alpm.Errno.EXTERNAL_DOWNLOAD) {
						current_error.details = { Alpm.strerror (errnos) };
					}
				}
			}
			return success;
		}

		private void refresh () {
			current_error = ErrorInfos ();
			write_log_file ("synchronizing package lists");
			cancellable.reset ();
			int force = (force_refresh) ? 1 : 0;
			// try to copy refresh dbs in tmp
			string tmp_dbpath = "/tmp/pamac-checkdbs";
			try {
				Process.spawn_command_line_sync ("cp -au %s/sync %s".printf (tmp_dbpath, alpm_handle.dbpath));
			} catch (SpawnError e) {
				stderr.printf ("SpawnError: %s\n", e.message);
			}
			// a new handle is required to use copied databases
			refresh_handle ();
			// update ".db"
			bool success = update_dbs (alpm_handle, force);
			if (cancellable.is_cancelled ()) {
				refresh_finished (false);
				return;
			}
			// update ".files", do not need to know if we succeeded
			update_dbs (files_handle, force);
			if (cancellable.is_cancelled ()) {
				refresh_finished (false);
			} else if (success) {
				refreshed = true;
				refresh_finished (true);
			} else {
				current_error.message = _("Failed to synchronize any databases");
				refresh_finished (false);
			}
		}

		public void start_refresh (bool force, GLib.BusName sender) throws DBusError, IOError {
			if (lock_id != sender) {
				refresh_finished (false);
				return;
			}
			force_refresh = force;
			if (force_refresh) {
				refreshed = false;
			}
			if (refreshed) {
				refresh_finished (true);
				return;
			}
			try {
				thread_pool.add (new AlpmAction (refresh));
			} catch (ThreadError e) {
				stderr.printf ("Thread Error %s\n", e.message);
			}
		}

		private void add_ignorepkgs () {
			foreach (unowned string pkgname in temporary_ignorepkgs) {
				alpm_handle.add_ignorepkg (pkgname);
			}
		}

		private void remove_ignorepkgs () {
			foreach (unowned string pkgname in temporary_ignorepkgs) {
				alpm_handle.remove_ignorepkg (pkgname);
			}
			temporary_ignorepkgs = {};
		}

		private AlpmPackage initialise_pkg_struct (Alpm.Package? alpm_pkg) {
			if (alpm_pkg != null) {
				string repo_name = "";
				if (alpm_pkg.origin == Alpm.Package.From.LOCALDB) {
					unowned Alpm.Package? sync_pkg = get_syncpkg (alpm_pkg.name);
					if (sync_pkg != null) {
						repo_name = sync_pkg.db.name;
					}
				} else if (alpm_pkg.origin == Alpm.Package.From.SYNCDB) {
					repo_name = alpm_pkg.db.name;
				}
				return AlpmPackage () {
					name = alpm_pkg.name,
					version = alpm_pkg.version,
					// desc can be null
					desc = alpm_pkg.desc ?? "",
					repo = (owned) repo_name,
					size = alpm_pkg.isize,
					origin = (uint) alpm_pkg.origin
				};
			} else {
				return AlpmPackage () {
					name = "",
					version = "",
					desc = "",
					repo = ""
				};
			}
		}

		private unowned Alpm.Package? get_syncpkg (string name) {
			unowned Alpm.Package? pkg = null;
			unowned Alpm.List<unowned Alpm.DB> syncdbs = alpm_handle.syncdbs;
			while (syncdbs != null) {
				unowned Alpm.DB db = syncdbs.data;
				pkg = db.get_pkg (name);
				if (pkg != null) {
					break;
				}
				syncdbs.next ();
			}
			return pkg;
		}

#if DISABLE_AUR
#else
		private AURPackage initialise_aur_struct (Json.Object json_object) {
			string installed_version = "";
			unowned Alpm.Package? pkg = alpm_handle.localdb.get_pkg (json_object.get_string_member ("Name"));
			if (pkg != null) {
				installed_version = pkg.version;
			}
			return AURPackage () {
				name = json_object.get_string_member ("Name"),
				version = json_object.get_string_member ("Version"),
				installed_version = (owned) installed_version,
				// desc can be null
				desc = json_object.get_null_member ("Description") ? "" : json_object.get_string_member ("Description"),
				popularity = json_object.get_double_member ("Popularity")
			};
		}

		private async void compute_aur_build_list (string[] aur_list) {
			try {
				Process.spawn_command_line_sync ("mkdir -p %s".printf (aurdb_path));
			} catch (SpawnError e) {
				stderr.printf ("SpawnError: %s\n", e.message);
			}
			aur_desc_list.remove_all ();
			already_checked_aur_dep.remove_all ();
			yield check_aur_dep_list (aur_list);
		}

		private async void check_aur_dep_list (string[] pkgnames) {
			string[] dep_types = {"Depends", "MakeDepends", "CheckDepends"};
			string[] dep_to_check = {};
			Json.Array results = yield multiinfo (pkgnames);
			results.foreach_element ((array, index, node) => {
				unowned Json.Object? pkg_info = node.get_object ();
				// create fake db desc file
				if (pkg_info != null) {
					string name = pkg_info.get_string_member ("Name");
					string version = pkg_info.get_string_member ("Version");
					string pkgdir = "%s-%s".printf (name, version);
					string pkgdir_path = "%s/%s".printf (aurdb_path, pkgdir);
					aur_desc_list.add (pkgdir);
					already_checked_aur_dep.add (name);
					try {
						var file = GLib.File.new_for_path (pkgdir_path);
						bool write_desc_file = false;
						if (!file.query_exists ()) {
							file.make_directory ();
							write_desc_file = true;
						}
						// compute depends, makedepends and checkdepends in DEPENDS
						var depends = new StringBuilder ();
						foreach (unowned string dep_type in dep_types) {
							unowned Json.Node? dep_node = pkg_info.get_member (dep_type);
							if (dep_node != null) {
								dep_node.get_array ().foreach_element ((array, index, node) => {
									if (write_desc_file) {
										depends.append (node.get_string ());
										depends.append ("\n");
									}
									// check deps
									unowned string dep_string = node.get_string ();
									string dep_name = Alpm.Depend.from_string (dep_string).name;
									unowned Alpm.Package? pkg = null;
									// search for the name first to avoid provides trouble
									pkg = alpm_handle.localdb.get_pkg (dep_name);
									if (pkg == null) {
										pkg = get_syncpkg (dep_name);
									}
									if (pkg == null) {
										if (!(dep_name in already_checked_aur_dep)) {
											dep_to_check += (owned) dep_name;
										}
									}
								});
							}
						}
						if (write_desc_file) {
							file = GLib.File.new_for_path ("%s/desc".printf (pkgdir_path));
							// creating a DataOutputStream to the file
							var dos = new DataOutputStream (file.create (FileCreateFlags.REPLACE_DESTINATION));
							// fake filename
							dos.put_string ("%FILENAME%\n" + "%s-%s-any.pkg.tar.xz\n\n".printf (name, version));
							// name
							dos.put_string ("%NAME%\n%s\n\n".printf (name));
							// version
							dos.put_string ("%VERSION%\n%s\n\n".printf (version));
							//base
							dos.put_string ("%BASE%\n%s\n\n".printf (pkg_info.get_string_member ("PackageBase")));
							// desc can be null
							if (!pkg_info.get_null_member ("Description")) {
								dos.put_string ("%DESC%\n%s\n\n".printf (pkg_info.get_string_member ("Description")));
							}
							// version
							dos.put_string ("%VERSION%\n%s\n\n".printf (pkg_info.get_string_member ("Version")));
							// fake arch
							dos.put_string ("%ARCH%\nany\n\n");
							// depends
							if (depends.len > 0) {
								dos.put_string ("%DEPENDS%\n%s\n".printf (depends.str));
							}
							// conflicts
							unowned Json.Node? info_node = pkg_info.get_member ("Conflicts");
							if (info_node != null) {
								try {
									dos.put_string ("%CONFLICTS%\n");
									info_node.get_array ().foreach_element ((array, index, _node) => {
										try {
											dos.put_string ("%s\n".printf (_node.get_string ()));
										} catch (GLib.Error e) {
											stderr.printf("%s\n", e.message);
										}
									});
									dos.put_string ("\n");
								} catch (GLib.Error e) {
									stderr.printf("%s\n", e.message);
								}
							}
							// provides
							info_node = pkg_info.get_member ("Provides");
							if (info_node != null) {
								try {
									dos.put_string ("%PROVIDES%\n");
									info_node.get_array ().foreach_element ((array, index, _node) => {
										try {
											dos.put_string ("%s\n".printf (_node.get_string ()));
										} catch (GLib.Error e) {
											stderr.printf("%s\n", e.message);
										}
									});
									dos.put_string ("\n");
								} catch (GLib.Error e) {
									stderr.printf("%s\n", e.message);
								}
							}
							// replaces
							info_node = pkg_info.get_member ("Replaces");
							if (info_node != null) {
								try {
									dos.put_string ("%REPLACES%\n");
									info_node.get_array ().foreach_element ((array, index, _node) => {
										try {
											dos.put_string ("%s\n".printf (_node.get_string ()));
										} catch (GLib.Error e) {
											stderr.printf("%s\n", e.message);
										}
									});
									dos.put_string ("\n");
								} catch (GLib.Error e) {
									stderr.printf("%s\n", e.message);
								}
							}
						}
					} catch (GLib.Error e) {
						stderr.printf("%s\n", e.message);
					}
				}
			});
			if (dep_to_check.length > 0) {
				yield check_aur_dep_list (dep_to_check);
			}
		}
#endif

		private void get_updates () {
			AlpmPackage[] updates_infos = {};
			unowned Alpm.Package? pkg = null;
			unowned Alpm.Package? candidate = null;
			foreach (unowned string name in alpm_config.get_syncfirsts ()) {
				pkg = Alpm.find_satisfier (alpm_handle.localdb.pkgcache, name);
				if (pkg != null) {
					candidate = pkg.get_new_version (alpm_handle.syncdbs);
					if (candidate != null) {
						var infos = initialise_pkg_struct (candidate);
						infos.installed_version = pkg.version;
						updates_infos += (owned) infos;
					}
				}
			}
			if (updates_infos.length != 0) {
				var updates = Updates () {
					is_syncfirst = true,
#if DISABLE_AUR
					repos_updates = (owned) updates_infos
#else
					repos_updates = (owned) updates_infos,
					aur_updates = {}
#endif
				};
				get_updates_finished (updates);
			} else {
#if DISABLE_AUR
#else
				string[] local_pkgs = {};
#endif
				unowned Alpm.List<unowned Alpm.Package> pkgcache = alpm_handle.localdb.pkgcache;
				while (pkgcache != null) {
					unowned Alpm.Package installed_pkg = pkgcache.data;
					// check if installed_pkg is in IgnorePkg or IgnoreGroup
					if (alpm_handle.should_ignore (installed_pkg) == 0) {
						candidate = installed_pkg.get_new_version (alpm_handle.syncdbs);
						if (candidate != null) {
							var infos = initialise_pkg_struct (candidate);
							infos.installed_version = installed_pkg.version;
							updates_infos += (owned) infos;
#if DISABLE_AUR
#else
						} else {
							if (check_aur_updates && (!aur_updates_checked)) {
								// check if installed_pkg is a local pkg
								unowned Alpm.List<unowned Alpm.DB> syncdbs = alpm_handle.syncdbs;
								while (syncdbs != null) {
									unowned Alpm.DB db = syncdbs.data;
									pkg = Alpm.find_satisfier (db.pkgcache, installed_pkg.name);
									if (pkg != null) {
										break;
									}
									syncdbs.next ();
								}
								if (pkg == null) {
									local_pkgs += installed_pkg.name;
								}
							}
#endif
						}
					}
					pkgcache.next ();
				}
#if DISABLE_AUR
#else
				if (check_aur_updates) {
					// get aur updates
					if (!aur_updates_checked) {
						multiinfo.begin (local_pkgs, (obj, res) => {
							aur_updates_results = multiinfo.end (res);
							aur_updates_checked = true;
							var updates = Updates () {
								is_syncfirst = false,
								repos_updates = (owned) updates_infos,
								aur_updates = get_aur_updates_infos ()
							};
							get_updates_finished (updates);
						});
					} else {
						var updates = Updates () {
							is_syncfirst = false,
							repos_updates = (owned) updates_infos,
							aur_updates = get_aur_updates_infos ()
						};
						get_updates_finished (updates);
					}
				} else {
#endif
					var updates = Updates () {
						is_syncfirst = false,
#if DISABLE_AUR
						repos_updates = (owned) updates_infos
#else
						repos_updates = (owned) updates_infos,
						aur_updates = {}
#endif
					};
					get_updates_finished (updates);
#if DISABLE_AUR
#else
				}
#endif
			}
		}

#if DISABLE_AUR
#else
		private AURPackage[] get_aur_updates_infos () {
			AURPackage[] aur_updates_infos = {};
			aur_updates_results.foreach_element ((array, index, node) => {
				unowned Json.Object pkg_info = node.get_object ();
				unowned string name = pkg_info.get_string_member ("Name");
				unowned string new_version = pkg_info.get_string_member ("Version");
				unowned string old_version = alpm_handle.localdb.get_pkg (name).version;
				if (Alpm.pkg_vercmp (new_version, old_version) == 1) {
					var infos = initialise_aur_struct (pkg_info);
					infos.installed_version = old_version;
					aur_updates_infos += (owned) infos;
				}
			});
			return aur_updates_infos;
		}
#endif

#if DISABLE_AUR
		public void start_get_updates () throws DBusError, IOError {
#else
		public void start_get_updates (bool check_aur_updates_) throws DBusError, IOError {
			check_aur_updates = check_aur_updates_;
#endif
			try {
				thread_pool.add (new AlpmAction (get_updates));
			} catch (ThreadError e) {
				stderr.printf ("Thread Error %s\n", e.message);
			}
		}

		private bool trans_init (Alpm.TransFlag flags) {
			current_error = ErrorInfos ();
			cancellable.reset ();
			if (alpm_handle.trans_init (flags) == -1) {
				Alpm.Errno errnos = alpm_handle.errno ();
				current_error.errnos = (uint) errnos;
				current_error.message = _("Failed to init transaction");
				if (errnos != 0) {
					current_error.details = { Alpm.strerror (errnos) };
				}
				return false;
			}
			return true;
		}

		private void sysupgrade_prepare () {
			current_error = ErrorInfos ();
			bool success = trans_init (0);
			if (success) {
				add_ignorepkgs ();
				if (alpm_handle.trans_sysupgrade ((enable_downgrade) ? 1 : 0) == -1) {
					Alpm.Errno errnos = alpm_handle.errno ();
					current_error.errnos = (uint) errnos;
					current_error.message = _("Failed to prepare transaction");
					if (errnos != 0) {
						current_error.details = { Alpm.strerror (errnos) };
					}
					try {
						trans_release (lock_id);
					} catch (IOError e) {
						stderr.printf ("IOError: %s\n", e.message);
					} catch (DBusError e) {
						stderr.printf ("DBusError: %s\n", e.message);
					}
					success = false;
				} else {
					success = trans_prepare_real ();
				}
			}
			trans_prepare_finished (success);
		}

		public void start_sysupgrade_prepare (bool enable_downgrade_, string[] temporary_ignorepkgs_, GLib.BusName sender) throws DBusError, IOError {
			if (lock_id != sender) {
				trans_prepare_finished (false);
				return;
			}
			enable_downgrade = enable_downgrade_;
			temporary_ignorepkgs = temporary_ignorepkgs_;
			try {
				thread_pool.add (new AlpmAction (sysupgrade_prepare));
			} catch (ThreadError e) {
				stderr.printf ("Thread Error %s\n", e.message);
			}
		}

		private bool trans_add_pkg_real (Alpm.Package pkg) {
			current_error = ErrorInfos ();
			if (alpm_handle.trans_add_pkg (pkg) == -1) {
				Alpm.Errno errnos = alpm_handle.errno ();
				if (errnos == Alpm.Errno.TRANS_DUP_TARGET || errnos == Alpm.Errno.PKG_IGNORED) {
					// just skip duplicate or ignored targets
					return true;
				} else {
					current_error.errnos = (uint) errnos;
					current_error.message = _("Failed to prepare transaction");
					if (errnos != 0) {
						current_error.details = { "%s: %s".printf (pkg.name, Alpm.strerror (errnos)) };
					}
					return false;
				}
			}
			return true;
		}

		private bool trans_add_pkg (string pkgname) {
			current_error = ErrorInfos ();
			unowned Alpm.Package? pkg = get_syncpkg (pkgname);
			if (pkg == null) {
				current_error.message = _("Failed to prepare transaction");
				current_error.details = { _("target not found: %s").printf (pkgname) };
				return false;
			} else {
				bool success = trans_add_pkg_real (pkg);
				if (success) {
					if (("linux31" in pkg.name) || ("linux4" in pkg.name)) {
						string[] installed_kernels = {};
						string[] installed_modules = {};
						unowned Alpm.List<unowned Alpm.Package> pkgcache = alpm_handle.localdb.pkgcache;
						while (pkgcache != null) {
							unowned Alpm.Package local_pkg = pkgcache.data;
							if (("linux31" in local_pkg.name) || ("linux4" in local_pkg.name)) {
								string[] local_pkg_splitted = local_pkg.name.split ("-", 2);
								if ((local_pkg_splitted[0] in installed_kernels) == false) {
									installed_kernels += local_pkg_splitted[0];
								}
								if (local_pkg_splitted.length == 2) {
									if ((local_pkg_splitted[1] in installed_modules) == false) {
										installed_modules += local_pkg_splitted[1];
									}
								}
							}
							pkgcache.next ();
						}
						string[] splitted = pkg.name.split ("-", 2);
						if (splitted.length == 2) {
							// we are adding a module
							// add the same module for other installed kernels
							foreach (unowned string installed_kernel in installed_kernels) {
								string module = installed_kernel + "-" + splitted[1];
								unowned Alpm.Package? installed_module_pkg = alpm_handle.localdb.get_pkg (module);
								if (installed_module_pkg == null) {
									unowned Alpm.Package? module_pkg = get_syncpkg (module);
									if (module_pkg != null) {
										trans_add_pkg_real (module_pkg);
									}
								}
							}
						} else if (splitted.length == 1) {
							// we are adding a kernel
							// add all installed modules for other kernels
							foreach (unowned string installed_module in installed_modules) {
								string module = splitted[0] + "-" + installed_module;
								unowned Alpm.Package? module_pkg = get_syncpkg (module);
								if (module_pkg != null) {
									trans_add_pkg_real (module_pkg);
								}
							}
						}
					}
				}
				return success;
			}
		}

		private bool trans_load_pkg (string pkgpath) {
			current_error = ErrorInfos ();
			Alpm.Package* pkg;
			if (alpm_handle.load_tarball (pkgpath, 1, alpm_handle.localfilesiglevel, out pkg) == -1) {
				Alpm.Errno errnos = alpm_handle.errno ();
				current_error.errnos = (uint) errnos;
				current_error.message = _("Failed to prepare transaction");
				if (errnos != 0) {
					current_error.details = { "%s: %s".printf (pkgpath, Alpm.strerror (errnos)) };
				}
				return false;
			} else if (alpm_handle.trans_add_pkg (pkg) == -1) {
				Alpm.Errno errnos = alpm_handle.errno ();
				if (errnos == Alpm.Errno.TRANS_DUP_TARGET || errnos == Alpm.Errno.PKG_IGNORED) {
					// just skip duplicate or ignored targets
					return true;
				} else {
					current_error.errnos = (uint) errnos;
					current_error.message = _("Failed to prepare transaction");
					if (errnos != 0) {
						current_error.details = { "%s: %s".printf (pkg->name, Alpm.strerror (errnos)) };
					}
					// free the package because it will not be used
					delete pkg;
					return false;
				}
			}
			return true;
		}

		private bool trans_remove_pkg (string pkgname) {
			current_error = ErrorInfos ();
			unowned Alpm.Package? pkg =  alpm_handle.localdb.get_pkg (pkgname);
			if (pkg == null) {
				current_error.message = _("Failed to prepare transaction");
				current_error.details = { _("target not found: %s").printf (pkgname) };
				return false;
			} else if (alpm_handle.trans_remove_pkg (pkg) == -1) {
				Alpm.Errno errnos = alpm_handle.errno ();
				if (errnos == Alpm.Errno.TRANS_DUP_TARGET) {
					// just skip duplicate targets
					return true;
				} else {
					current_error.errnos = (uint) errnos;
					current_error.message = _("Failed to prepare transaction");
					if (errnos != 0) {
						current_error.details = { "%s: %s".printf (pkg.name, Alpm.strerror (errnos)) };
					}
					return false;
				}
			}
			return true;
		}

		private bool trans_prepare_real () {
			bool success = true;
			current_error = ErrorInfos ();
			string[] details = {};
			Alpm.List err_data;
			if (alpm_handle.trans_prepare (out err_data) == -1) {
				Alpm.Errno errnos = alpm_handle.errno ();
				current_error.errnos = (uint) errnos;
				current_error.message = _("Failed to prepare transaction");
				switch (errnos) {
					case 0:
						break;
					case Alpm.Errno.PKG_INVALID_ARCH:
						details += Alpm.strerror (errnos) + ":";
						unowned Alpm.List<string*> list = err_data;
						while (list != null) {
							string* pkgname = list.data;
							details += _("package %s does not have a valid architecture").printf (pkgname);
							delete pkgname;
							list.next ();
						}
						break;
					case Alpm.Errno.UNSATISFIED_DEPS:
						details += Alpm.strerror (errnos) + ":";
						unowned Alpm.List<Alpm.DepMissing*> list = err_data;
						while (list != null) {
							Alpm.DepMissing* miss = list.data;
							string depstring = miss->depend.compute_string ();
							unowned Alpm.List<unowned Alpm.Package> trans_add = alpm_handle.trans_to_add ();
							unowned Alpm.Package pkg;
							string detail;
							if (miss->causingpkg == null) {
								/* package being installed/upgraded has unresolved dependency */
								detail = _("unable to satisfy dependency '%s' required by %s").printf (depstring, miss->target);
							} else if ((pkg = Alpm.pkg_find (trans_add, miss->causingpkg)) != null) {
								/* upgrading a package breaks a local dependency */
								detail = _("installing %s (%s) breaks dependency '%s' required by %s").printf (miss->causingpkg, pkg.version, depstring, miss->target);
							} else {
								/* removing a package breaks a local dependency */
								detail = _("removing %s breaks dependency '%s' required by %s").printf (miss->causingpkg, depstring, miss->target);
							}
							if (!(detail in details)) {
								details += detail;
							}
							delete miss;
							list.next ();
						}
						break;
					case Alpm.Errno.CONFLICTING_DEPS:
						details += Alpm.strerror (errnos) + ":";
						unowned Alpm.List<Alpm.Conflict*> list = err_data;
						while (list != null) {
							Alpm.Conflict* conflict = list.data;
							string conflict_detail = _("%s and %s are in conflict").printf (conflict->package1, conflict->package2);
							// only print reason if it contains new information
							if (conflict->reason.mod != Alpm.Depend.Mode.ANY) {
								conflict_detail += " (%s)".printf (conflict->reason.compute_string ());
							}
							details += (owned) conflict_detail;
							delete conflict;
							list.next ();
						}
						break;
					default:
						details += Alpm.strerror (errnos);
						break;
				}
				current_error.details = (owned) details;
				try {
					trans_release (lock_id);
				} catch (IOError e) {
					stderr.printf ("IOError: %s\n", e.message);
				} catch (DBusError e) {
					stderr.printf ("DBusError: %s\n", e.message);
				}
				success = false;
			} else {
				// Search for holdpkg in target list
				bool found_locked_pkg = false;
				unowned Alpm.List<unowned Alpm.Package> to_remove = alpm_handle.trans_to_remove ();
				while (to_remove != null) {
					unowned Alpm.Package pkg = to_remove.data;
					if (alpm_config.get_holdpkgs ().find_custom (pkg.name, strcmp) != null) {
						details += _("%s needs to be removed but it is a locked package").printf (pkg.name);
						found_locked_pkg = true;
						break;
					}
					to_remove.next ();
				}
				if (found_locked_pkg) {
					current_error.message = _("Failed to prepare transaction");
					current_error.details = (owned) details;
					try {
						trans_release (lock_id);
					} catch (IOError e) {
						stderr.printf ("IOError: %s\n", e.message);
					} catch (DBusError e) {
						stderr.printf ("DBusError: %s\n", e.message);
					}
					success = false;
				}
			}
			return success;
		}

		private void trans_prepare () {
			bool success = trans_init (flags);
			if (success) {
				foreach (unowned string name in to_install) {
					success = trans_add_pkg (name);
					if (!success) {
						break;
					}
				}
				if (success) {
					foreach (unowned string name in to_remove) {
						success = trans_remove_pkg (name);
						if (!success) {
							break;
						}
					}
				}
				if (success) {
					foreach (unowned string path in to_load) {
						success = trans_load_pkg (path);
						if (!success) {
							break;
						}
					}
				}
				if (success) {
					success = trans_prepare_real ();
				} else {
					try {
						trans_release (lock_id);
					} catch (IOError e) {
						stderr.printf ("IOError: %s\n", e.message);
					} catch (DBusError e) {
						stderr.printf ("DBusError: %s\n", e.message);
					}
				}
			}
			trans_prepare_finished (success);
		}

#if DISABLE_AUR
#else
		private void build_prepare () {
			// create a fake aur db
			try {
				var list = new StringBuilder ();
				foreach (unowned string name_version in aur_desc_list) {
					list.append (name_version);
					list.append (" ");
				}
				Process.spawn_command_line_sync ("rm -f %ssync/aur.db".printf (alpm_handle.dbpath));
				Process.spawn_command_line_sync ("bsdtar -cf %ssync/aur.db -C %s %s".printf (alpm_handle.dbpath, aurdb_path, list.str));
			} catch (SpawnError e) {
				stderr.printf ("SpawnError: %s\n", e.message);
			}
			// get an handle without emit signal callbacks AND fake aur db
			alpm_handle = alpm_config.get_handle ();
			if (alpm_handle == null) {
				current_error = ErrorInfos () {
					message = _("Failed to initialize alpm library")
				};
				trans_commit_finished (false);
			} else {
				alpm_handle.set_questioncb((Alpm.QuestionCallBack) cb_question, null);
				lockfile = GLib.File.new_for_path (alpm_handle.lockfile);
				// fake aur db
				alpm_handle.register_syncdb ("aur", 0);
				// add to_build in to_install for the fake trans prpeapre
				foreach (unowned string name in to_build) {
					to_install += name;
					// check if we need to remove debug package to avoid dep problem
					string debug_pkg_name = "%s-debug".printf (name);
					if (alpm_handle.localdb.get_pkg (debug_pkg_name) != null) {
						to_remove += debug_pkg_name;
					}
				}
				// check base-devel group needed to build pkgs
				var backup_to_remove = new GenericSet<string?> (str_hash, str_equal);
				foreach (unowned string name in to_remove) {
					backup_to_remove.add (name);
				}
				unowned Alpm.List<unowned Alpm.DB> syncdbs = alpm_handle.syncdbs;
				while (syncdbs != null) {
					unowned Alpm.DB db = syncdbs.data;
					unowned Alpm.Group? grp = db.get_group ("base-devel");
					if (grp != null) {
						unowned Alpm.List<unowned Alpm.Package> packages = grp.packages;
						while (packages != null) {
							unowned Alpm.Package pkg = packages.data;
							if (Alpm.find_satisfier (alpm_handle.localdb.pkgcache, pkg.name) == null) {
								to_install += pkg.name;
							} else {
								// remove the needed pkg from to_remove
								backup_to_remove.remove (pkg.name);
							}
							packages.next ();
						}
					}
					syncdbs.next ();
				}
				// check git needed to build pkgs
				if (Alpm.find_satisfier (alpm_handle.localdb.pkgcache, "git") == null) {
					to_install += "git";
				} else {
					// remove the needed pkg from to_remove
					backup_to_remove.remove ("git");
				}
				to_remove = {};
				foreach (unowned string name in backup_to_remove) {
					to_remove += name;
				}
				// fake trans prepare
				current_error = ErrorInfos ();
				bool success = true;
				if (alpm_handle.trans_init (flags | Alpm.TransFlag.NOLOCK) == -1) {
					Alpm.Errno errnos = alpm_handle.errno ();
					current_error.errnos = (uint) errnos;
					current_error.message = _("Failed to init transaction");
					if (errnos != 0) {
						current_error.details = { Alpm.strerror (errnos) };
					}
					success = false;
				}
				if (success) {
					foreach (unowned string name in to_install) {
						success = trans_add_pkg (name);
						if (!success) {
							break;
						}
					}
					if (success) {
						foreach (unowned string name in to_remove) {
							success = trans_remove_pkg (name);
							if (!success) {
								break;
							}
						}
					}
					if (success) {
						foreach (unowned string path in to_load) {
							success = trans_load_pkg (path);
							if (!success) {
								break;
							}
						}
					}
					if (success) {
						success = trans_prepare_real ();
						if (success) {
							// check trans preparation result
							string[] real_to_install = {};
							unowned Alpm.List<unowned Alpm.Package> pkgs_to_add = alpm_handle.trans_to_add ();
							while (pkgs_to_add != null) {
								unowned Alpm.Package trans_pkg = pkgs_to_add.data;
								unowned Alpm.DB? db = trans_pkg.db;
								if (db != null) {
									if (db.name == "aur") {
										// it is a aur pkg to build
										aur_pkgbases_to_build.append (trans_pkg.pkgbase);
										var infos = UpdateInfos () {
											name = trans_pkg.name,
											old_version = "",
											new_version = trans_pkg.version,
											repo = "",
											download_size = 0
										};
										to_build_infos += (owned) infos;
										if (!(trans_pkg.name in to_build)) {
											to_install_as_dep.insert (trans_pkg.name, trans_pkg.name);
										}
									} else {
										// it is a pkg to install
										real_to_install += trans_pkg.name;
										if (!(trans_pkg.name in to_install)) {
											to_install_as_dep.insert (trans_pkg.name, trans_pkg.name);
										}
									}
								}
								pkgs_to_add.next ();
							}
							aur_conflicts_to_remove = {};
							unowned Alpm.List<unowned Alpm.Package> pkgs_to_remove = alpm_handle.trans_to_remove ();
							while (pkgs_to_remove != null) {
								unowned Alpm.Package trans_pkg = pkgs_to_remove.data;
								// it is a pkg to remove
								if (!(trans_pkg.name in to_remove)) {
									var infos = UpdateInfos () {
										name = trans_pkg.name,
										old_version = trans_pkg.version,
										new_version = "",
										repo = "",
										download_size = 0
									};
									aur_conflicts_to_remove += (owned) infos;
								}
								pkgs_to_remove.next ();
							}
							try {
								trans_release (lock_id);
							} catch (IOError e) {
								stderr.printf ("IOError: %s\n", e.message);
							} catch (DBusError e) {
								stderr.printf ("DBusError: %s\n", e.message);
							}
							try {
								Process.spawn_command_line_sync ("rm -f %ssync/aur.db".printf (alpm_handle.dbpath));
							} catch (SpawnError e) {
								stderr.printf ("SpawnError: %s\n", e.message);
							}
							// get standard handle
							refresh_handle ();
							// launch standard prepare
							to_install = real_to_install;
							trans_prepare ();
						}
					} else {
						try {
							trans_release (lock_id);
						} catch (IOError e) {
							stderr.printf ("IOError: %s\n", e.message);
						} catch (DBusError e) {
							stderr.printf ("DBusError: %s\n", e.message);
						}
					}
				}
				if (!success) {
					// get standard handle
					refresh_handle ();
					trans_prepare_finished (false);
				}
			}
		}
#endif

#if DISABLE_AUR
		public void start_trans_prepare (Alpm.TransFlag flags_,
										string[] to_install_,
										string[] to_remove_,
										string[] to_load_,
										GLib.BusName sender) throws DBusError, IOError {
#else
		public void start_trans_prepare (Alpm.TransFlag flags_,
										string[] to_install_,
										string[] to_remove_,
										string[] to_load_,
										string[] to_build_,
										GLib.BusName sender) throws DBusError, IOError {
#endif
			if (lock_id != sender) {
				trans_prepare_finished (false);
				return;
			}
			flags = flags_;
			to_install = to_install_;
			to_remove = to_remove_;
			to_load = to_load_;
#if DISABLE_AUR
#else
			to_build = to_build_;
			to_build_infos = {};
			aur_pkgbases_to_build = new GLib.List<string> ();
			if (to_build.length != 0) {
				compute_aur_build_list.begin (to_build, (obj, res) => {
					try {
						thread_pool.add (new AlpmAction (build_prepare));
					} catch (ThreadError e) {
						stderr.printf ("Thread Error %s\n", e.message);
					}
				});
			} else {
#endif
				try {
					thread_pool.add (new AlpmAction (trans_prepare));
				} catch (ThreadError e) {
					stderr.printf ("Thread Error %s\n", e.message);
				}
#if DISABLE_AUR
#else
			}
#endif
		}

		public void choose_provider (int provider) throws DBusError, IOError {
			provider_mutex.lock ();
			choosen_provider = provider;
			provider_cond.signal ();
			provider_mutex.unlock ();
		}

		public TransactionSummary get_transaction_summary () throws DBusError, IOError {
			UpdateInfos[] to_install = {};
			UpdateInfos[] to_upgrade = {};
			UpdateInfos[] to_downgrade = {};
			UpdateInfos[] to_reinstall = {};
			UpdateInfos[] to_remove = {};
			unowned Alpm.List<unowned Alpm.Package> pkgs_to_add = alpm_handle.trans_to_add ();
			while (pkgs_to_add != null) {
				unowned Alpm.Package trans_pkg = pkgs_to_add.data;
				unowned Alpm.Package? local_pkg = alpm_handle.localdb.get_pkg (trans_pkg.name);
				var infos = UpdateInfos () {
					name = trans_pkg.name,
					old_version = local_pkg != null ? local_pkg.version : "",
					new_version = trans_pkg.version,
					// if pkg was load from a file, pkg.db is null
					repo =trans_pkg.db != null ? trans_pkg.db.name : "",
					download_size = trans_pkg.download_size
				};
				if (local_pkg == null) {
					to_install += (owned) infos;
				} else {
					int cmp = Alpm.pkg_vercmp (trans_pkg.version, local_pkg.version);
					if (cmp == 1) {
						to_upgrade += (owned) infos;
					} else if (cmp == 0) {
						to_reinstall += (owned) infos;
					} else {
						to_downgrade += (owned) infos;
					}
				}
				pkgs_to_add.next ();
			}
			unowned Alpm.List<unowned Alpm.Package> pkgs_to_remove = alpm_handle.trans_to_remove ();
			while (pkgs_to_remove != null) {
				unowned Alpm.Package trans_pkg = pkgs_to_remove.data;
				var infos = UpdateInfos () {
					name = trans_pkg.name,
					old_version = trans_pkg.version,
					new_version = "",
					repo = trans_pkg.db.name
				};
				to_remove += (owned) infos;
				pkgs_to_remove.next ();
			}
#if DISABLE_AUR
#else
			UpdateInfos[] conflicts_to_remove = {};
			foreach (unowned UpdateInfos infos in aur_conflicts_to_remove){
				conflicts_to_remove += infos;
			}
			aur_conflicts_to_remove = {};
			string[] pkgbases_to_build = {};
			foreach (unowned string name in aur_pkgbases_to_build) {
				pkgbases_to_build += name;
			}
#endif
			var summary = TransactionSummary () {
				to_install = (owned) to_install,
				to_upgrade = (owned) to_upgrade,
				to_downgrade = (owned) to_downgrade,
				to_reinstall = (owned) to_reinstall,
#if DISABLE_AUR
				to_remove = (owned) to_remove
#else
				to_remove = (owned) to_remove,
				to_build = to_build_infos,
				aur_conflicts_to_remove = conflicts_to_remove,
				aur_pkgbases_to_build = pkgbases_to_build
#endif
			};
			return summary;
		}

		private void trans_commit () {
			current_error = ErrorInfos ();
			bool success = true;
			Alpm.List err_data;
			if (alpm_handle.trans_commit (out err_data) == -1) {
				Alpm.Errno errnos = alpm_handle.errno ();
				current_error.errnos = (uint) errnos;
				// cancel the download return an EXTERNAL_DOWNLOAD error
				if (errnos == Alpm.Errno.EXTERNAL_DOWNLOAD && cancellable.is_cancelled ()) {
					try {
						trans_release (lock_id);
					} catch (IOError e) {
						stderr.printf ("IOError: %s\n", e.message);
					} catch (DBusError e) {
						stderr.printf ("DBusError: %s\n", e.message);
					}
					trans_commit_finished (false);
					return;
				}
				current_error.message = _("Failed to commit transaction");
				switch (errnos) {
					case 0:
						break;
					case Alpm.Errno.FILE_CONFLICTS:
						string[] details = {};
						details += Alpm.strerror (errnos) + ":";
						//TransFlag flags = alpm_handle.trans_get_flags ();
						//if ((flags & TransFlag.FORCE) != 0) {
							//details += _("unable to %s directory-file conflicts").printf ("--force");
						//}
						unowned Alpm.List<Alpm.FileConflict*> list = err_data;
						while (list != null) {
							Alpm.FileConflict* conflict = list.data;
							switch (conflict->type) {
								case Alpm.FileConflict.Type.TARGET:
									details += _("%s exists in both %s and %s").printf (conflict->file, conflict->target, conflict->ctarget);
									break;
								case Alpm.FileConflict.Type.FILESYSTEM:
									details += _("%s: %s already exists in filesystem").printf (conflict->target, conflict->file);
									break;
							}
							delete conflict;
							list.next ();
						}
						current_error.details = (owned) details;
						break;
					case Alpm.Errno.PKG_INVALID:
					case Alpm.Errno.PKG_INVALID_CHECKSUM:
					case Alpm.Errno.PKG_INVALID_SIG:
						string[] details = {};
						details += Alpm.strerror (errnos) + ":";
						unowned Alpm.List<string*> list = err_data;
						while (list != null) {
							string* filename = list.data;
							details += _("%s is invalid or corrupted").printf (filename);
							delete filename;
							list.next ();
						}
						current_error.details = (owned) details;
						break;
					case Alpm.Errno.EXTERNAL_DOWNLOAD:
						// details are set in cb_fetch
						break;
					default:
						current_error.details = {Alpm.strerror (errnos)};
						break;
				}
				success = false;
			}
			try {
				trans_release (lock_id);
			} catch (IOError e) {
				stderr.printf ("IOError: %s\n", e.message);
			} catch (DBusError e) {
				stderr.printf ("DBusError: %s\n", e.message);
			}
			to_install_as_dep.foreach_remove ((pkgname, val) => {
				unowned Alpm.Package? pkg = alpm_handle.localdb.get_pkg (pkgname);
				if (pkg != null) {
					pkg.reason = Alpm.Package.Reason.DEPEND;
					return true; // remove current pkgname
				}
				return false;
			});
			trans_commit_finished (success);
		}

		public void start_trans_commit (GLib.BusName sender) throws DBusError, IOError {
			check_authorization.begin (sender, (obj, res) => {
				bool authorized = check_authorization.end (res);
				if (authorized) {
					try {
						thread_pool.add (new AlpmAction (trans_commit));
					} catch (ThreadError e) {
						stderr.printf ("Thread Error %s\n", e.message);
					}
				} else {
					try {
						trans_release (lock_id);
					} catch (IOError e) {
						stderr.printf ("IOError: %s\n", e.message);
					} catch (DBusError e) {
						stderr.printf ("DBusError: %s\n", e.message);
					}
					trans_commit_finished (false);
				}
			});
		}

		public void trans_release (GLib.BusName sender) throws DBusError, IOError {
			if (lock_id != sender) {
				return;
			}
			alpm_handle.trans_release ();
			remove_ignorepkgs ();
		}

		public void trans_cancel (GLib.BusName sender) throws DBusError, IOError {
			if (lock_id != sender) {
				return;
			}
			if (alpm_handle.trans_interrupt () == 0) {
				// a transaction is being interrupted
				// it will end the normal way
				return;
			}
			cancellable.cancel ();
		}

		[DBus (no_reply = true)]
		public void quit () throws DBusError, IOError {
			// wait for all tasks to be processed
			ThreadPool.free ((owned) thread_pool, false, true);
			loop.quit ();
		}
	// End of Daemon Object
	}
}

private void write_log_file (string event) {
	var now = new DateTime.now_local ();
	string log = "%s [PAMAC] %s\n".printf (now.format ("[%Y-%m-%d %H:%M]"), event);
	var file = GLib.File.new_for_path ("/var/log/pacman.log");
	try {
		// creating a DataOutputStream to the file
		var dos = new DataOutputStream (file.append_to (FileCreateFlags.NONE));
		// writing a short string to the stream
		dos.put_string (log);
	} catch (GLib.Error e) {
		stderr.printf ("%s\n", e.message);
	}
}

private void cb_event (void *ctx, Alpm.Event.Data data) {
	string[] details = {};
	uint secondary_type = 0;
	switch (data.type) {
		case Alpm.Event.Type.HOOK_START:
			switch (data.hook_when) {
				case Alpm.HookWhen.PRE_TRANSACTION:
					secondary_type = (uint) Alpm.HookWhen.PRE_TRANSACTION;
					break;
				case Alpm.HookWhen.POST_TRANSACTION:
					secondary_type = (uint) Alpm.HookWhen.POST_TRANSACTION;
					break;
				default:
					break;
			}
			break;
		case Alpm.Event.Type.HOOK_RUN_START:
			details += data.hook_run_name;
			details += data.hook_run_desc ?? "";
			details += data.hook_run_position.to_string ();
			details += data.hook_run_total.to_string ();
			break;
		case Alpm.Event.Type.PACKAGE_OPERATION_START:
			switch (data.package_operation_operation) {
				case Alpm.Package.Operation.REMOVE:
					details += data.package_operation_oldpkg.name;
					details += data.package_operation_oldpkg.version;
					secondary_type = (uint) Alpm.Package.Operation.REMOVE;
					break;
				case Alpm.Package.Operation.INSTALL:
					details += data.package_operation_newpkg.name;
					details += data.package_operation_newpkg.version;
					secondary_type = (uint) Alpm.Package.Operation.INSTALL;
					break;
				case Alpm.Package.Operation.REINSTALL:
					details += data.package_operation_newpkg.name;
					details += data.package_operation_newpkg.version;
					secondary_type = (uint) Alpm.Package.Operation.REINSTALL;
					break;
				case Alpm.Package.Operation.UPGRADE:
					details += data.package_operation_oldpkg.name;
					details += data.package_operation_oldpkg.version;
					details += data.package_operation_newpkg.version;
					secondary_type = (uint) Alpm.Package.Operation.UPGRADE;
					break;
				case Alpm.Package.Operation.DOWNGRADE:
					details += data.package_operation_oldpkg.name;
					details += data.package_operation_oldpkg.version;
					details += data.package_operation_newpkg.version;
					secondary_type = (uint) Alpm.Package.Operation.DOWNGRADE;
					break;
				default:
					break;
			}
			break;
		case Alpm.Event.Type.SCRIPTLET_INFO:
			details += data.scriptlet_info_line;
			break;
		case Alpm.Event.Type.PKG_RETRIEVE_START:
			// do not emit event when download is cancelled
			if (system_daemon.cancellable.is_cancelled ()) {
				return;
			}
			system_daemon.emit_totaldownload (data.pkg_retrieve_total_size);
			// event will be emitted by cb_fetch
			return;
		case Alpm.Event.Type.OPTDEP_REMOVAL:
			details += data.optdep_removal_pkg.name;
			details += data.optdep_removal_optdep.compute_string ();
			break;
		case Alpm.Event.Type.DATABASE_MISSING:
			details += data.database_missing_dbname;
			break;
		case Alpm.Event.Type.PACNEW_CREATED:
			details += data.pacnew_created_file;
			break;
		case Alpm.Event.Type.PACSAVE_CREATED:
			details += data.pacsave_created_file;
			break;
		default:
			break;
	}
	system_daemon.emit_event ((uint) data.type, secondary_type, details);
}

private void cb_question (void *ctx, Alpm.Question.Data data) {
	switch (data.type) {
		case Alpm.Question.Type.INSTALL_IGNOREPKG:
			// Do not install package in IgnorePkg/IgnoreGroup
			data.install_ignorepkg_install = 0;
			break;
		case Alpm.Question.Type.REPLACE_PKG:
			// Auto-remove conflicts in case of replaces
			data.replace_replace = 1;
			break;
		case Alpm.Question.Type.CONFLICT_PKG:
			// Auto-remove conflicts
			data.conflict_remove = 1;
			break;
		case Alpm.Question.Type.REMOVE_PKGS:
			// Return an error if there are top-level packages which have unresolvable dependencies
			data.remove_pkgs_skip = 0;
			break;
		case Alpm.Question.Type.SELECT_PROVIDER:
			string depend_str = data.select_provider_depend.compute_string ();
			string[] providers_str = {};
			unowned Alpm.List<unowned Alpm.Package> list = data.select_provider_providers;
			while (list != null) {
				unowned Alpm.Package pkg = list.data;
				providers_str += pkg.name;
				list.next ();
			}
			system_daemon.provider_cond = Cond ();
			system_daemon.provider_mutex = Mutex ();
			system_daemon.choosen_provider = null;
			system_daemon.emit_providers (depend_str, providers_str);
			system_daemon.provider_mutex.lock ();
			while (system_daemon.choosen_provider == null) {
				system_daemon.provider_cond.wait (system_daemon.provider_mutex);
			}
			data.select_provider_use_index = system_daemon.choosen_provider;
			system_daemon.provider_mutex.unlock ();
			break;
		case Alpm.Question.Type.CORRUPTED_PKG:
			// Auto-remove corrupted pkgs in cache
			data.corrupted_remove = 1;
			break;
		case Alpm.Question.Type.IMPORT_KEY:
			if (data.import_key_key.revoked == 1) {
				// Do not get revoked key
				data.import_key_import = 0;
			} else {
				// Auto get not revoked key
				data.import_key_import = 1;
			}
			break;
		default:
			data.any_answer = 0;
			break;
	}
}

private void cb_progress (void *ctx, Alpm.Progress progress, string pkgname, int percent, uint n_targets, uint current_target) {
	if (percent == 0) {
		system_daemon.emit_progress ((uint) progress, pkgname, (uint) percent, n_targets, current_target);
		system_daemon.timer.start ();
	} else if (percent == 100) {
		system_daemon.emit_progress ((uint) progress, pkgname, (uint) percent, n_targets, current_target);
		system_daemon.timer.stop ();
	}else if (system_daemon.timer.elapsed () < 0.5) {
		return;
	} else {
		system_daemon.emit_progress ((uint) progress, pkgname, (uint) percent, n_targets, current_target);
		system_daemon.timer.start ();
	}
}

private uint64 prevprogress;

private int cb_curldownload (void* data, uint64 dltotal, uint64 dlnow, uint64 ultotal, uint64 ulnow) {

	if (unlikely (system_daemon.cancellable.is_cancelled ())) {
		return 1;
	}

	string filename = (string) data;

	if (unlikely (dlnow == 0 || dltotal == 0 || prevprogress == dltotal)) {
		return 0;
	} else if (unlikely (prevprogress == 0)) {
		system_daemon.emit_download (filename, 0, dltotal);
		system_daemon.emit_download (filename, dlnow, dltotal);
		system_daemon.timer.start ();
	} else if (unlikely (dlnow == dltotal)) {
		system_daemon.emit_download (filename, dlnow, dltotal);
		system_daemon.timer.stop ();
	} else if (likely (system_daemon.timer.elapsed () < 0.5)) {
		return 0;
	} else {
		system_daemon.emit_download (filename, dlnow, dltotal);
		system_daemon.timer.start ();
	}

	prevprogress = dlnow;

	return 0;
}

private int cb_fetch (void *ctx, string fileurl, string localpath, int force) {
	if (system_daemon.cancellable.is_cancelled ()) {
		return -1;
	}

	char error_buffer[Curl.ERROR_SIZE];
	var url = GLib.File.new_for_uri (fileurl);
	var destfile = GLib.File.new_for_path (localpath + url.get_basename ());
	var tempfile = GLib.File.new_for_path (destfile.get_path () + ".part");

	system_daemon.emit_event(Alpm.Event.Type.PKG_RETRIEVE_START, 0, {url.get_basename ()});

	system_daemon.curl.reset ();
	system_daemon.curl.setopt (Curl.Option.FAILONERROR, 1L);
	system_daemon.curl.setopt (Curl.Option.CONNECTTIMEOUT, 30L);
	system_daemon.curl.setopt (Curl.Option.FILETIME, 1L);
	system_daemon.curl.setopt (Curl.Option.FOLLOWLOCATION, 1L);
	system_daemon.curl.setopt (Curl.Option.XFERINFOFUNCTION, cb_curldownload);
	system_daemon.curl.setopt (Curl.Option.LOW_SPEED_LIMIT, 1L);
	system_daemon.curl.setopt (Curl.Option.LOW_SPEED_TIME, 30L);
	system_daemon.curl.setopt (Curl.Option.NETRC, Curl.NetRCOption.OPTIONAL);
	system_daemon.curl.setopt (Curl.Option.HTTPAUTH, Curl.CURLAUTH_ANY);
	system_daemon.curl.setopt (Curl.Option.URL, fileurl);
	system_daemon.curl.setopt (Curl.Option.ERRORBUFFER, error_buffer);
	system_daemon.curl.setopt (Curl.Option.NOPROGRESS, 0L);
	system_daemon.curl.setopt (Curl.Option.XFERINFODATA, (void*) url.get_basename ());

	bool remove_partial_download = true;
	if (fileurl.contains (".pkg.tar.") && !fileurl.has_suffix (".sig")) {
		remove_partial_download = false;
	}

	string open_mode = "wb";
	prevprogress = 0;

	try {
		if (force == 0) {
			if (destfile.query_exists ()) {
				// start from scratch only download if our local is out of date.
				system_daemon.curl.setopt (Curl.Option.TIMECONDITION, Curl.TimeCond.IFMODSINCE);
				FileInfo info = destfile.query_info ("time::modified", 0);
				DateTime time = info.get_modification_date_time ();
				system_daemon.curl.setopt (Curl.Option.TIMEVALUE, time.to_unix());
			} else if (tempfile.query_exists ()) {
				// a previous partial download exists, resume from end of file.
				FileInfo info = tempfile.query_info ("standard::size", 0);
				int64 size = info.get_size ();
				system_daemon.curl.setopt (Curl.Option.RESUME_FROM_LARGE, size);
				open_mode = "ab";
			}
		} else {
			if (tempfile.query_exists ()) {
				tempfile.delete ();
			}
		}
	} catch (GLib.Error e) {
		stderr.printf ("Error: %s\n", e.message);
	}

	Posix.FILE localf = Posix.FILE.open (tempfile.get_path (), open_mode);
	if (localf == null) {
		stderr.printf ("could not open file %s\n", tempfile.get_path ());
		return -1;
	}

	system_daemon.curl.setopt (Curl.Option.WRITEDATA, localf);

	// perform transfer
	Curl.Code err = system_daemon.curl.perform ();


	// disconnect relationships from the curl handle for things that might go out
	// of scope, but could still be touched on connection teardown. This really
	// only applies to FTP transfers.
	system_daemon.curl.setopt (Curl.Option.NOPROGRESS, 1L);
	system_daemon.curl.setopt (Curl.Option.ERRORBUFFER, null);

	int ret;

	// was it a success?
	switch (err) {
		case Curl.Code.OK:
			long timecond, remote_time = -1;
			double remote_size, bytes_dl;
			unowned string effective_url;

			// retrieve info about the state of the transfer
			system_daemon.curl.getinfo (Curl.Info.FILETIME, out remote_time);
			system_daemon.curl.getinfo (Curl.Info.CONTENT_LENGTH_DOWNLOAD, out remote_size);
			system_daemon.curl.getinfo (Curl.Info.SIZE_DOWNLOAD, out bytes_dl);
			system_daemon.curl.getinfo (Curl.Info.CONDITION_UNMET, out timecond);
			system_daemon.curl.getinfo (Curl.Info.EFFECTIVE_URL, out effective_url);

			if (timecond == 1 && bytes_dl == 0) {
				// time condition was met and we didn't download anything. we need to
				// clean up the 0 byte .part file that's left behind.
				try {
					if (tempfile.query_exists ()) {
						tempfile.delete ();
					}
				} catch (GLib.Error e) {
					stderr.printf ("Error: %s\n", e.message);
				}
				ret = 1;
			}
			// remote_size isn't necessarily the full size of the file, just what the
			// server reported as remaining to download. compare it to what curl reported
			// as actually being transferred during curl_easy_perform ()
			else if (remote_size != -1 && bytes_dl != -1 && bytes_dl != remote_size) {
				string error = _("%s appears to be truncated: %jd/%jd bytes\n").printf (
											fileurl, bytes_dl, remote_size);
				system_daemon.emit_log ((uint) Alpm.LogLevel.ERROR, error);
				system_daemon.current_error.details = {error};
				if (remove_partial_download) {
					try {
						if (tempfile.query_exists ()) {
							tempfile.delete ();
						}
					} catch (GLib.Error e) {
						stderr.printf ("Error: %s\n", e.message);
					}
				}
				ret = -1;
			} else {
				try {
					tempfile.move (destfile, FileCopyFlags.OVERWRITE);
				} catch (GLib.Error e) {
					stderr.printf ("Error: %s\n", e.message);
				}
				ret = 0;
			}
			break;
		case Curl.Code.ABORTED_BY_CALLBACK:
			if (remove_partial_download) {
				try {
					if (tempfile.query_exists ()) {
						tempfile.delete ();
					}
				} catch (GLib.Error e) {
					stderr.printf ("Error: %s\n", e.message);
				}
			}
			ret = -1;
			break;
		default:
			// other cases are errors
			try {
				if (tempfile.query_exists ()) {
					if (remove_partial_download) {
						tempfile.delete ();
					} else {
						// delete zero length downloads
						FileInfo info = tempfile.query_info ("standard::size", 0);
						int64 size = info.get_size ();
						if (size == 0) {
							tempfile.delete ();
						}
					}
				}
			} catch (GLib.Error e) {
				stderr.printf ("Error: %s\n", e.message);
			}
			// do not report error for missing sig
			if (!fileurl.has_suffix (".sig")) {
				string hostname = url.get_uri ().split("/")[2];
				string error = _("failed retrieving file '%s' from %s : %s\n").printf (
											url.get_basename (), hostname, (string) error_buffer);
				system_daemon.emit_log ((uint) Alpm.LogLevel.ERROR, error);
				system_daemon.current_error.details = {error};
			}
			ret = -1;
			break;
	}

	return ret;
}

private void cb_download (void* ctx, string filename, Alpm.Download.Event event_type, void* event_data) {
	if (event_type == Alpm.Download.Event.COMPLETED) {
		system_daemon.emit_totaldownload (((Alpm.Download.Completed) event_data).total);
	}
}

private void cb_log (void *ctx, Alpm.LogLevel level, string fmt, va_list args) {
	// do not log errors when download is cancelled
	if (system_daemon.cancellable.is_cancelled ()) {
		return;
	}
	Alpm.LogLevel logmask = Alpm.LogLevel.ERROR | Alpm.LogLevel.WARNING;
	if ((level & logmask) == 0) {
		return;
	}
	string? log = null;
	log = fmt.vprintf (args);
	if (log != null) {
		system_daemon.emit_log ((uint) level, log);
	}
}

void on_bus_acquired (DBusConnection conn) {
	system_daemon = new Pamac.SystemDaemon ();
	try {
		conn.register_object ("/org/pamac/system", system_daemon);
	}
	catch (IOError e) {
		stderr.printf ("Could not register service\n");
		loop.quit ();
	}
}

void main () {
	// i18n
	Intl.bindtextdomain(Constants.GETTEXT_PACKAGE, Path.build_filename(Constants.DATADIR,"locale"));
	Intl.setlocale (LocaleCategory.ALL, "");
	Intl.textdomain(Constants.GETTEXT_PACKAGE);
	Intl.bind_textdomain_codeset(Constants.GETTEXT_PACKAGE, "utf-8" );

	Bus.own_name (BusType.SYSTEM,
				"org.pamac.system",
				BusNameOwnerFlags.NONE,
				on_bus_acquired,
				null,
				() => {
					stderr.printf ("Could not acquire name\n");
					loop.quit ();
				});

	Curl.global_init (Curl.GLOBAL_SSL);
	loop = new MainLoop ();
	loop.run ();
	Curl.global_cleanup ();
}
