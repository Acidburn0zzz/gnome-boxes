// This file is part of GNOME Boxes. License: LGPLv2+
using GVir;
using Gtk;

private class Boxes.LibvirtMachine: Boxes.Machine {
    public GVir.Domain domain;
    public GVirConfig.Domain domain_config;
    public GVir.Connection connection;
    public GVir.StorageVol? storage_volume;
    public VMCreator? vm_creator; // Under installation if this is set to non-null

    public bool save_on_quit {
        get { return source.get_boolean ("source", "save-on-quit"); }
        set { source.set_boolean ("source", "save-on-quit", value); }
    }

    public override void disconnect_display () {
        stay_on_display = false;

        base.disconnect_display ();
    }

    public override async void connect_display () throws GLib.Error {
        yield start ();

        if (update_display ()) {
            display.connect_it ();
        } else {
            show_display ();
            display.set_enable_audio (true);
        }
    }

    struct MachineStat {
        int64 timestamp;
        double cpu_time;
        double cpu_time_abs;
        double cpu_guest_percent;
        double memory_percent;
        DomainDiskStats disk;
        double disk_read;
        double disk_write;
        DomainInterfaceStats net;
        double net_read;
        double net_write;
    }

    private uint shutdown_timeout;

    private uint stats_update_timeout;
    private Cancellable stats_cancellable;

    static const int STATS_SIZE = 20;
    private MachineStat[] stats;

    private bool force_stopped;

    construct {
        stats = new MachineStat[STATS_SIZE];
        stats_cancellable = new Cancellable ();
        can_save = true;
    }

    private void update_domain_config () {
        try {
            domain_config = domain.get_config (GVir.DomainXMLFlags.NONE);
            storage_volume = get_storage_volume (connection, domain);
        } catch (GLib.Error error) {
            critical ("Failed to fetch configuration for domain '%s': %s", domain.get_name (), error.message);
        }
    }

    private void reconnect_display () {
        // If we haven't connected yet, don't reconnect
        if (display == null)
            return;

        disconnect_display ();
        connect_display.begin ();
    }

    public LibvirtMachine (CollectionSource source,
                           GVir.Connection connection,
                           GVir.Domain     domain) throws GLib.Error {
        var config = domain.get_config (GVir.DomainXMLFlags.INACTIVE);
        var item_name = config.get_title () ?? domain.get_name ();
        base (source, item_name);

        debug ("new libvirt machine: " + domain.get_name ());
        create_display_config (domain.get_uuid ());
        this.connection = connection;
        this.domain = domain;

        try {
            var s = domain.get_info ().state;
            switch (s) {
            case DomainState.RUNNING:
            case DomainState.BLOCKED:
                state = MachineState.RUNNING;
                set_stats_enable (true);
                break;
            case DomainState.PAUSED:
                state = MachineState.PAUSED;
                break;
            case DomainState.SHUTDOWN:
            case DomainState.SHUTOFF:
                if (domain.get_saved ())
                    state = MachineState.SAVED;
                else
                    state = MachineState.STOPPED;
                break;
            case DomainState.CRASHED:
                state = MachineState.STOPPED;
                break;
            case DomainState.PMSUSPENDED:
                state = MachineState.SLEEPING;
                break;
            default:
            case DomainState.NONE:
                state = MachineState.UNKNOWN;
                break;
            }
        } catch (GLib.Error error) {
            state = MachineState.UNKNOWN;
        }

        domain.started.connect (() => { state = MachineState.RUNNING; });
        domain.suspended.connect (() => { state = MachineState.PAUSED; });
        domain.resumed.connect (() => { state = MachineState.RUNNING; });
        domain.stopped.connect (() => {
            if (Signal.get_invocation_hint (this.domain).detail == Quark.from_string ("saved"))
                state = MachineState.SAVED;
            else if (force_stopped) {
                force_stopped = false;
                state = MachineState.FORCE_STOPPED;
            } else
                state = MachineState.STOPPED;
        });
        domain.pmsuspended.connect (() => {
            state = MachineState.SLEEPING;
        });
        notify["state"].connect (() => {
            if (state == MachineState.RUNNING) {
                reconnect_display ();
                set_stats_enable (true);
            } else
                set_stats_enable (false);
        });

        update_domain_config ();
        domain.updated.connect (update_domain_config);

        if (state != MachineState.STOPPED)
            load_screenshot ();
        set_screenshot_enable (true);
    }

    private void update_cpu_stat (DomainInfo info, ref MachineStat stat) {
        var prev = stats[STATS_SIZE - 1];

        if (info.state == DomainState.CRASHED ||
            info.state == DomainState.SHUTOFF)
            return;

        stat.cpu_time = info.cpuTime - prev.cpu_time_abs;
        stat.cpu_time_abs = info.cpuTime;
        // hmm, where does this x10 come from?
        var dt = (stat.timestamp - prev.timestamp) * 10;
        var percent = stat.cpu_time / dt;
        percent = percent / info.nrVirtCpu;
        stat.cpu_guest_percent = percent.clamp (0, 100);
    }

    private void update_mem_stat (DomainInfo info, ref MachineStat stat) {
        if (info.state != DomainState.RUNNING)
            return;

        stat.memory_percent = info.memory * 100.0 / info.maxMem;
    }

    private async void update_io_stat (DomainInfo info, MachineStat *stat) {
        if (info.state != DomainState.RUNNING)
            return;

        try {
            var disk = get_domain_disk ();
            if (disk == null)
                return;

            yield run_in_thread ( () => {
                    stat.disk = disk.get_stats ();
                } );
            var prev = stats[STATS_SIZE - 1];
            if (prev.disk != null) {
                stat.disk_read = (stat.disk.rd_bytes - prev.disk.rd_bytes);
                stat.disk_write = (stat.disk.wr_bytes - prev.disk.wr_bytes);
            }
        } catch (GLib.Error err) {
            warning ("Failed to fetch I/O statistics for %s: %s", name, err.message);
        }
    }

    private async void update_net_stat (DomainInfo info, MachineStat *stat) {
        if (info.state != DomainState.RUNNING)
            return;

        try {
            var net = get_domain_network_interface ();
            if (net == null)
                return;

            yield run_in_thread ( () => {
                    stat.net = net.get_stats ();
                } );
            var prev = stats[STATS_SIZE - 1];
            if (prev.net != null) {
                stat.net_read = (stat.net.rx_bytes - prev.net.rx_bytes);
                stat.net_write = (stat.net.tx_bytes - prev.net.tx_bytes);
            }
        } catch (GLib.Error err) {
            warning ("Failed to fetch network statistics for %s: %s", name, err.message);
        }
    }

    public signal void stats_updated ();

    public double[] cpu_stats;
    public double[] io_stats;
    public double[] net_stats;
    private async void update_stats () {
        try {
            var now = get_monotonic_time ();
            var stat = MachineStat () { timestamp = now };
            var info = yield domain.get_info_async (stats_cancellable);

            update_cpu_stat (info, ref stat);
            update_mem_stat (info, ref stat);
            yield update_io_stat (info, &stat);
            yield update_net_stat (info, &stat);

            stats = stats[1:STATS_SIZE];
            stats += stat;

        } catch (IOError.CANCELLED err) {
            return;
        } catch (GLib.Error err) {
            warning (err.message);
        }

        cpu_stats = {};
        io_stats = {};
        net_stats = {};

        foreach (var stat in stats) {
            cpu_stats += stat.cpu_guest_percent;
            net_stats += (stat.net_read + stat.net_write);
            io_stats += (stat.disk_read + stat.disk_write);
        }

        stats_updated ();
    }

    private void set_stats_enable (bool enable) {
        if (enable) {
            debug ("enable statistics for " + name);
            if (stats_update_timeout != 0)
                return;

            stats_cancellable.reset ();
            var stats_updating = false;
            stats_update_timeout = Timeout.add_seconds (1, () => {
                if (stats_updating) {
                    warning ("Fetching of stats for '%s' is taking too long. Probably a libvirt bug.", name);

                    return true;
                }

                stats_updating = true;
                update_stats.begin (() => { stats_updating = false; });

                return true;
            });
        } else {
            debug ("disable statistics for " + name);
            if (stats_update_timeout != 0) {
                stats_cancellable.cancel ();
                GLib.Source.remove (stats_update_timeout);
            }
            stats_update_timeout = 0;
        }
    }

    public void try_change_name (string name) throws Boxes.Error {
        try {
            var config = domain.get_config (GVir.DomainXMLFlags.INACTIVE);
            // Te use libvirt "title" for free form user name
            config.title = name;
            // This will take effect only after next reboot, but we use pending/inactive config for name and title
            domain.set_config (config);

            this.name = name;
        } catch (GLib.Error error) {
            warning ("Failed to change title of box '%s' to '%s': %s",
                     domain.get_name (), name, error.message);
            throw new Boxes.Error.INVALID ("Invalid libvirt title");
        }
    }

    public void try_enable_usb_redir () throws GLib.Error {
        var config = domain.get_config (GVir.DomainXMLFlags.INACTIVE);

        // Remove any old usb configuration from old config
        VMConfigurator.remove_usb_controllers (config);

        // Add usb redirection channel and usb2 controllers
        VMConfigurator.add_usb_support (config);

        // This will take effect only after next reboot
        domain.set_config (config);
        if (is_on ())
            notify_reboot_required ();
    }

    private string collect_logs () {
        var builder = new StringBuilder ();

        builder.append_printf ("Domain: %s\n", domain.get_name ());
        builder.append_printf ("UUID: %s\n", domain.get_uuid ());
        builder.append_printf ("Persistent: %s\n", domain.get_persistent () ? "yes" : "no");
        try {
            var info = domain.get_info ();
            builder.append_printf ("Cpu time: %"+uint64.FORMAT_MODIFIER+"d\n", info.cpuTime);
            builder.append_printf ("Memory: %"+uint64.FORMAT_MODIFIER+"d\n", info.memory);
            builder.append_printf ("Max memory: %"+uint64.FORMAT_MODIFIER+"d\n", info.maxMem);
            builder.append_printf ("CPUs: %d\n", info.nrVirtCpu);
            builder.append_printf ("State: %s\n", info.state.to_string ());
        } catch (GLib.Error e) {
        }

        if (display != null)
            display.collect_logs (builder);


        try {
            var conf = domain.get_config (GVir.DomainXMLFlags.NONE);
            builder.append_printf ("\nDomain config:\n");
            builder.append_printf ("------------------------------------------------------------\n");

            builder.append (conf.to_xml ());
            builder.append_printf ("\n" +
                                   "------------------------------------------------------------\n");
        } catch (GLib.Error error) {
        }

        try {
            var logfile = Path.build_filename (Environment.get_user_cache_dir (), "libvirt/qemu/log", domain.get_name ()  + ".log");
            string data;
            FileUtils.get_contents (logfile, out data);
            builder.append_printf ("\nQEMU log:\n");
            builder.append_printf ("------------------------------------------------------------\n");

            builder.append (data);
            builder.append_printf ("------------------------------------------------------------\n");
        } catch (GLib.Error e) {
        }
        return builder.str;
    }

    public override List<Boxes.Property> get_properties (Boxes.PropertiesPage page, PropertyCreationFlag flags) {
        var list = new List<Boxes.Property> ();

        // the wizard may want to modify display properties, before connect_display()
        if (display == null)
            try {
                update_display ();
            } catch (GLib.Error e) {
                warning (e.message);
            }

        switch (page) {
        case PropertiesPage.LOGIN:
            add_string_property (ref list, _("Name"), name, (property, name) => {
                try_change_name (name);
            });
            add_string_property (ref list, _("Virtualizer"), source.uri);
            if (display != null)
                add_string_property (ref list, _("URI"), display.uri);
            break;

        case PropertiesPage.SYSTEM:
            add_ram_property (ref list);
            add_storage_property (ref list);

            var button = new Gtk.Button.with_label (_("Troubleshooting log"));
            button.halign = Gtk.Align.START;
            add_property (ref list, null, button);
            button.clicked.connect (() => {
                var log = collect_logs ();
                var dialog = new Gtk.Dialog.with_buttons (_("Troubleshooting log"),
                                                          App.app.window,
                                                          DialogFlags.DESTROY_WITH_PARENT,
                                                          Stock.SAVE, 100,
                                                          _("Copy to clipboard"), 101,
                                                          Stock.CLOSE, ResponseType.OK);
                dialog.set_default_size (640, 480);
                var text = new Gtk.TextView ();
                text.editable = false;
                var scroll = new Gtk.ScrolledWindow (null, null);
                scroll.add (text);
                scroll.vexpand = true;

                dialog.get_content_area ().add (scroll);
                text.buffer.set_text (log);
                dialog.show_all ();

                dialog.response.connect ( (response_id) => {
                    if (response_id == 100) {
                        var chooser = new Gtk.FileChooserDialog (_("Save log"), App.app.window,
                                                                 Gtk.FileChooserAction.SAVE,
                                                                 Stock.SAVE, ResponseType.OK);
                        chooser.local_only = false;
                        chooser.do_overwrite_confirmation = true;
                        chooser.response.connect ((response_id) => {
                            if (response_id == ResponseType.OK) {
                                var file = chooser.get_file ();
                                try {
                                    file.replace_contents (log.data, null, false,
                                                           FileCreateFlags.REPLACE_DESTINATION, null);
                                } catch (GLib.Error e) {
                                    var m = new Gtk.MessageDialog (chooser,
                                                                   Gtk.DialogFlags.DESTROY_WITH_PARENT,
                                                                   Gtk.MessageType.ERROR,
                                                                   Gtk.ButtonsType.CLOSE,
                                                                   _("Error saving: %s").printf (e.message));
                                    m.show_all ();
                                    m.response.connect ( () => { m.destroy (); });
                                    return;
                                }
                                chooser.destroy ();
                            } else {
                                chooser.destroy ();
                            }
                        });
                        chooser.show_all ();
                    } else if (response_id == 101){
                        Gtk.Clipboard.get_for_display (dialog.get_display (), Gdk.SELECTION_CLIPBOARD).set_text (log, -1);
                    } else {
                        dialog.destroy ();
                    }
                });
            });
            break;

        case PropertiesPage.DISPLAY:
            if (display != null)
                add_string_property (ref list, _("Protocol"), display.protocol);
            break;

        case PropertiesPage.DEVICES:
            foreach (var device_config in domain_config.get_devices ()) {
                if (!(device_config is GVirConfig.DomainDisk))
                    continue;
                var disk_config = device_config as GVirConfig.DomainDisk;
                var disk_type = disk_config.get_guest_device_type ();
                if (disk_type == GVirConfig.DomainDiskGuestDeviceType.CDROM) {
                    var grid = new Gtk.Grid ();
                    grid.set_orientation (Gtk.Orientation.HORIZONTAL);
                    grid.set_column_spacing (12);

                    var label = new Gtk.Label ("");
                    grid.add (label);

                    var source = disk_config.get_source ();
                    bool empty = (source == null || source == "");

                    var button_label = new Gtk.Label ("");
                    var button = new Gtk.Button ();
                    button.add (button_label);

                    grid.add (button);

                    if (empty) {
                        // Translators: This is the text on the button to select an iso for the cd
                        button_label.set_text (_("Select"));
                        // Translators: empty is listed as the filename for a non-mounted CD
                        label.set_markup (Markup.printf_escaped ("<i>%s</i>", _("empty")));
                    } else {
                        // Translators: Remove is the label on the button to remove an iso from a cdrom drive
                        button_label.set_text (_("Remove"));
                        label.set_text (get_utf8_basename (source));
                    }

                    button.clicked.connect ( () => {
                        if (empty) {
                            var dialog = new Gtk.FileChooserDialog (_("Select a device or ISO file"),
                                                                    App.app.window,
                                                                    Gtk.FileChooserAction.OPEN,
                                                                    Gtk.Stock.CANCEL, Gtk.ResponseType.CANCEL,
                                                                    Gtk.Stock.OPEN, Gtk.ResponseType.ACCEPT);
                            dialog.modal = true;
                            dialog.show_hidden = false;
                            dialog.local_only = true;
                            dialog.filter = new Gtk.FileFilter ();
                            dialog.filter.add_mime_type ("application/x-cd-image");
                            dialog.response.connect ( (response) => {
                                if (response == Gtk.ResponseType.ACCEPT) {
                                    var path = dialog.get_filename ();
                                    disk_config.set_source (path);
                                    try {
                                        domain.update_device (disk_config, DomainUpdateDeviceFlags.CURRENT);
                                        button_label.set_text (_("Remove"));
                                        label.set_text (get_utf8_basename (path));
                                        empty = false;
                                    } catch (GLib.Error e) {
                                        got_error (e.message);
                                    }
                                }
                                dialog.destroy ();
                            });
                            dialog.show_all ();
                        } else {
                            disk_config.set_source ("");
                            try {
                                domain.update_device (disk_config, DomainUpdateDeviceFlags.CURRENT);
                                empty = true;
                                button_label.set_text (_("Select"));
                                label.set_markup (Markup.printf_escaped ("<i>%s</i>", _("empty")));
                            } catch (GLib.Error e) {
                                got_error (e.message);
                            }
                        }
                    });

                    add_property (ref list, _("CD/DVD"), grid);
                }
            }

            bool has_usb_redir = false;
            // We look at the INACTIVE config here, because we want to show the usb
            // widgetry if usb has been added already but we have not rebooted
            try {
                var inactive_config = domain.get_config (GVir.DomainXMLFlags.INACTIVE);
                foreach (var device in inactive_config.get_devices ()) {
                    if (device is GVirConfig.DomainRedirdev) {
                        has_usb_redir = true;
                        break;
                    }
                }
            } catch (GLib.Error error) {
                warning ("Failed to fetch configuration for domain '%s': %s", domain.get_name (), error.message);
            }

            if (!has_usb_redir)
                flags |= PropertyCreationFlag.NO_USB;

            /* Only add usb support to guests if HAVE_USBREDIR, as older
             * qemu versions break migration with it. */
            if (!has_usb_redir && Config.HAVE_USBREDIR) {
                var button = new Gtk.Button.with_label (_("Add support to guest"));
                button.halign = Gtk.Align.START;
                var property = add_property (ref list, _("USB device support"), button);
                button.clicked.connect (() => {
                    try {
                        try_enable_usb_redir ();
                        update_domain_config ();
                        property.refresh_properties ();
                    } catch (GLib.Error error) {
                        warning ("Failed to enable usb");
                    }
                });
            }

            break;
        }

        if (display != null)
            list.concat (display.get_properties (page,
                                                 flags));

        return list;
    }

    private bool update_display () throws GLib.Error {
        update_domain_config ();

        var created_display = display == null;
        if (display == null)
            display = create_display ();
        return created_display;
    }

    private Display? create_display () throws Boxes.Error {
        string type, port, socket, host;

        var xmldoc = domain_config.to_xml ();
        type = extract_xpath (xmldoc, "string(/domain/devices/graphics/@type)", true);
        port = extract_xpath (xmldoc, @"string(/domain/devices/graphics[@type='$type']/@port)");
        socket = extract_xpath (xmldoc, @"string(/domain/devices/graphics[@type='$type']/@socket)");
        host = extract_xpath (xmldoc, @"string(/domain/devices/graphics[@type='$type']/@listen)");

        if (host == null || host == "")
            host = "localhost";

        switch (type) {
        case "spice":
            return new SpiceDisplay (config, host, int.parse (port));

        case "vnc":
            return new VncDisplay (config, host, int.parse (port));

        default:
            throw new Boxes.Error.INVALID ("unsupported display of type " + type);
        }
    }

    public override async Gdk.Pixbuf? take_screenshot () throws GLib.Error {
        var state = DomainState.NONE;
        try {
            state = (yield domain.get_info_async (null)).state;
        } catch (GLib.Error error) {
            warning ("Failed to get information on '%s'", name);
        }

        if (state != DomainState.RUNNING && state != DomainState.PAUSED && state != DomainState.PMSUSPENDED)
            return null;

        var stream = connection.get_stream (0);
        yield run_in_thread (()=> {
            domain.screenshot (stream, 0, 0);
        });

        var loader = new Gdk.PixbufLoader ();
        var input_stream = stream.get_input_stream ();
        var buffer = new uint8[65535];
        ssize_t length = 0;
        do {
            length = yield input_stream.read_async (buffer);
            loader.write (buffer[0:length]);
        } while (length > 0);
        loader.close ();

        return loader.get_pixbuf ();
    }

    public override void delete (bool by_user = true) {
        debug ("delete libvirt machine: " + name);
        base.delete (by_user);

        set_stats_enable (false);
        if (shutdown_timeout != 0) {
            Source.remove (shutdown_timeout);
            shutdown_timeout = 0;
        }

        if (by_user) {
            var domain = this.domain; // Don't reference self in thread

            /* Run all the slow operations in a separate thread
               to avoid blocking the UI */
            run_in_thread.begin ( () => {
                try {
                    // This undefines the domain, causing it to be transient if it was running
                    domain.delete (DomainDeleteFlags.SAVED_STATE);
                } catch (GLib.Error err) {
                    warning (err.message);
                }

                try {
                    // Ensure that the domain is stopped before we touch any data
                    domain.stop (0);
                } catch (GLib.Error err) {
                    debug (err.message); // No warning cause this can easily fail for legitimate reasons
                }

                // Remove any images controlled by boxes
                if (storage_volume != null)
                    try {
                        storage_volume.delete (0);
                    } catch (GLib.Error err) {
                        warning (err.message);
                    }
            });
        }
    }

    public async override void save_real () throws GLib.Error {
        yield domain.save_async (0, null);
    }

    public async void suspend () throws GLib.Error {
        if (save_on_quit)
            yield save ();
        else
            domain.suspend ();
    }

    public void force_shutdown (bool confirm = true) {
        if (confirm) {
            var dialog = new Gtk.MessageDialog (App.app.window,
                                                Gtk.DialogFlags.DESTROY_WITH_PARENT,
                                                Gtk.MessageType.QUESTION,
                                                Gtk.ButtonsType.OK_CANCEL,
                                                _("When you force shutdown, the box may lose data."));
            var response = dialog.run ();
            dialog.destroy ();

            if (response != Gtk.ResponseType.OK)
                return;
        }

        debug ("Force shutdown '%s'..", name);
        try {
            force_stopped = true;
            domain.stop (0);
        } catch (GLib.Error error) {
            warning ("Failed to shutdown '%s': %s", domain.get_name (), error.message);
        }
    }

    private GVir.DomainDisk? get_domain_disk () throws GLib.Error {
        var disk = null as GVir.DomainDisk;

        foreach (var device_config in domain_config.get_devices ()) {
            if (device_config is GVirConfig.DomainDisk) {
                var disk_config = device_config as GVirConfig.DomainDisk;
                var disk_type = disk_config.get_guest_device_type ();
                var storage_volume_path = (storage_volume != null)? storage_volume.get_path () : null;

                // Prefer Boxes' managed volume over other disks
                if (disk_type == GVirConfig.DomainDiskGuestDeviceType.DISK &&
                    disk_config.get_source () == storage_volume_path) {
                    disk = Object.new (typeof (GVir.DomainDisk),
                                       "domain", domain,
                                       "config", device_config) as GVir.DomainDisk;

                    break;
                }
            }
        }

        return disk;
    }

    private GVir.DomainInterface? get_domain_network_interface () throws GLib.Error {
        var net = null as GVir.DomainInterface;

        // FiXME: We currently only entertain one network interface
        foreach (var device_config in domain_config.get_devices ()) {
            if (device_config is GVirConfig.DomainInterface) {
                net = Object.new (typeof (GVir.DomainInterface),
                                  "domain", domain,
                                  "config", device_config) as GVir.DomainInterface;
                break;
            }
        }

        return net;
    }

    private void update_ram_property (Boxes.Property property) {
        try {
            var config = domain.get_config (GVir.DomainXMLFlags.INACTIVE);

            // we use KiB unit, convert to MiB
            var actual = domain_config.memory / 1024;
            var pending = config.memory / 1024;

            debug ("RAM actual: %llu, pending: %llu", actual, pending);
            // somehow, there are rounded errors, so let's forget about 1Mb diff
            property.reboot_required = (actual - pending) > 1; // no need for abs()

        } catch (GLib.Error e) {}
    }

    private void add_ram_property (ref List list) {
        try {
            var max_ram = connection.get_node_info ().memory;

            var property = add_size_property (ref list,
                                              _("Memory"),
                                              domain_config.memory,
                                              Osinfo.MEBIBYTES / Osinfo.KIBIBYTES,
                                              max_ram,
                                              Osinfo.MEBIBYTES / Osinfo.KIBIBYTES,
                                              on_ram_changed);

            this.notify["state"].connect (() => {
                if (!is_on ())
                    property.reboot_required = false;
            });

            update_ram_property (property);
        } catch (GLib.Error error) {}
    }

    private void on_ram_changed (Boxes.Property property, uint64 value) {
        // Ensure that we don't end-up changing RAM like a 1000 times a second while user moves the slider..
        property.deferred_change = () => {
            try {
                var config = domain.get_config (GVir.DomainXMLFlags.INACTIVE);
                config.memory = value;
                if (config.get_class ().find_property ("current-memory") != null)
                    config.set ("current-memory", value);
                domain.set_config (config);
                debug ("RAM changed to %llu", value);
                if (is_on ())
                    notify_reboot_required ();
            } catch (GLib.Error error) {
                warning ("Failed to change RAM of box '%s' to %llu: %s",
                         domain.get_name (),
                         value,
                         error.message);
            }

            if (is_on ())
                update_ram_property (property);

            return false;
        };
    }

    private async void start () throws GLib.Error {
        if (state == MachineState.RUNNING)
            return;

        if (state == MachineState.PAUSED)
            yield domain.resume_async (null);
        else if (state == MachineState.SLEEPING) {
            yield domain.wakeup_async (0, null);
        } else {
            if (domain.get_saved ())
                // Translators: The %s will be expanded with the name of the vm
                status = _("Restoring %s from disk").printf (name);
            else
                // Translators: The %s will be expanded with the name of the vm
                status = _("Starting %s").printf (name);
            yield domain.start_async (0, null);
        }
    }


    private void notify_reboot_required () {
        Notificationbar.OKFunc reboot = () => {
            debug ("Rebooting '%s'..", name);
            stay_on_display = true;
            ulong state_id = 0;
            Gd.Notification notification = null;

            state_id = this.notify["state"].connect (() => {
                if (state == MachineState.STOPPED || state == MachineState.FORCE_STOPPED) {
                    debug ("'%s' stopped.", name);
                    start.begin ((obj, res) => {
                        try {
                            start.end (res);
                        } catch (GLib.Error error) {
                            warning ("Failed to start '%s': %s", domain.get_name (), error.message);
                        }
                    });
                    this.disconnect (state_id);
                    if (shutdown_timeout != 0) {
                        Source.remove (shutdown_timeout);
                        shutdown_timeout = 0;
                    }
                    if (notification != null) {
                        notification.dismiss ();
                        notification = null;
                    }
                }
            });

            shutdown_timeout = Timeout.add_seconds (5, () => {
                // Seems guest ignored ACPI shutdown, lets force shutdown with user's consent
                Notificationbar.OKFunc really_force_shutdown = () => {
                    notification = null;
                    force_shutdown (false);
                };

                var message = _("Restart of '%s' is taking too long. Force it to shutdown?").printf (name);
                notification = App.app.notificationbar.display_for_action (message,
                                                                           Gtk.Stock.YES,
                                                                           (owned) really_force_shutdown,
                                                                           null,
                                                                           -1);
                shutdown_timeout = 0;

                return false;
            });

            try {
                domain.shutdown (0);
            } catch (GLib.Error error) {
                warning ("Failed to reboot '%s': %s", domain.get_name (), error.message);
            }
        };
        var message = _("Changes require restart of '%s'. Attempt restart?").printf (name);
        App.app.notificationbar.display_for_action (message, Gtk.Stock.YES, (owned) reboot);
    }

    private void add_storage_property (ref List list) {
        if (storage_volume == null)
            return;

        try {
            var volume_info = storage_volume.get_info ();
            var pool = get_storage_pool (connection);
            var pool_info = pool.get_info ();
            var max_storage = (volume_info.capacity + pool_info.available)  / Osinfo.KIBIBYTES;

            add_size_property (ref list,
                               _("Maximum Disk Size"),
                               volume_info.capacity / Osinfo.KIBIBYTES,
                               volume_info.capacity / Osinfo.KIBIBYTES,
                               max_storage,
                               Osinfo.GIBIBYTES / Osinfo.KIBIBYTES,
                               on_storage_changed);
        } catch (GLib.Error error) {
            warning ("Failed to get information on volume '%s' or it's parent pool: %s",
                     storage_volume.get_name (),
                     error.message);
        }
    }

    private void on_storage_changed (Boxes.Property property, uint64 value) {
        // Ensure that we don't end-up changing storage like a 1000 times a second while user moves the slider..
        property.deferred_change = () => {
            if (storage_volume == null)
                return false;

            try {
                if (is_running ()) {
                    var disk = get_domain_disk ();
                    if (disk != null)
                        disk.resize (value, 0);
                } else
                    // Currently this never happens as properties page cant be reached without starting the machine
                    storage_volume.resize (value * Osinfo.KIBIBYTES, StorageVolResizeFlags.NONE);
                debug ("Storage changed to %llu", value);
            } catch (GLib.Error error) {
                warning ("Failed to change storage capacity of volume '%s' to %llu: %s",
                         storage_volume.get_name (),
                         value,
                         error.message);
            }

            return false;
        };
    }
}
