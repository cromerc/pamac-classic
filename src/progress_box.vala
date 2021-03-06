/*
 *  pamac-vala
 *
 *  Copyright (C) 2017 Chris Cromer <cromer@cromnix.org>
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

//using GIO

namespace Pamac {

	[GtkTemplate (ui = "/org/pamac/transaction/interface/progress_box.ui")]
	public class ProgressBox : Gtk.Box {

		[GtkChild]
		public unowned Gtk.ProgressBar progressbar;
		[GtkChild]
		public unowned Gtk.Label action_label;

		public ProgressBox () {
			Object ();
		}

	}
}
