#!/system/bin/sh
# Thermal Genie - 卸载清理
pkill -f "thermal_genie/bin/genie.sh" 2>/dev/null
pkill -f "thermal_genie/service.sh" 2>/dev/null
sleep 1
umount /vendor/etc/display/thermallevel_to_fps.xml 2>/dev/null
umount /my_product/etc/refresh_rate_config.xml 2>/dev/null
rm -rf /data/local/tmp/.thermal_genie.lock
rm -f /data/local/tmp/tog.log /data/local/tmp/rel.log /data/local/tmp/low.log \
      /data/local/tmp/s.log /data/local/tmp/ab.log /data/local/tmp/n.log \
      /data/local/tmp/on.txt /data/local/tmp/off.txt \
      /data/local/tmp/chg.log /data/local/tmp/chg2.log /data/local/tmp/togtest.sh
exit 0
