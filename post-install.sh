#
# Post-reboot setup
#

# Install AUR package helper
git clone < https://github.com/Jguer/yay > /tmp/yay
cd /tmp/yay
sudo pacman -S go
makepkg -si

sudo systemctl enable gdm.service
