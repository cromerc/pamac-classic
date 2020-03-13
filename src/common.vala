/*
 *  pamac-vala
 *
 *  Copyright (C) 2017 Chris Cromer <cromer@cromnix.org>
 *  Copyright (C) 2014-2015  Guillaume Benoit <guillaume@manjaro.org>
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
	public struct UpdateInfos {
		public string name;
		public string old_version;
		public string new_version;
		public string repo;
		public uint64 download_size;
	}

	public struct TransactionSummary {
		public UpdateInfos[] to_install;
		public UpdateInfos[] to_upgrade;
		public UpdateInfos[] to_downgrade;
		public UpdateInfos[] to_reinstall;
		public UpdateInfos[] to_remove;
		public UpdateInfos[] to_build;
#if DISABLE_AUR
#else
		public UpdateInfos[] aur_conflicts_to_remove;
		public string[] aur_pkgbases_to_build;
#endif
	}

	public struct Updates {
		public bool is_syncfirst;
		public AlpmPackage[] repos_updates;
#if DISABLE_AUR
#else
		public AURPackage[] aur_updates;
#endif
	}

	public struct ErrorInfos {
		public uint errnos;
		public string message;
		public string[] details;
		public ErrorInfos () {
			message = "";
		}
	}
}
