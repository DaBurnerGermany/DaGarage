ALTER TABLE `owned_vehicles`
    ADD COLUMN `dagarage_slot` INT UNSIGNED NULL,
    ADD UNIQUE KEY `uq_dagarage_owner_location_slot` (`owner`, `dagarage_location`, `dagarage_slot`);
