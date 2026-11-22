ALTER TABLE `player_vehicles`
    ADD COLUMN `dagarage_location` VARCHAR(60) NULL,
    ADD COLUMN `dagarage_slot` INT UNSIGNED NULL,
    ADD COLUMN `dagarage_society` VARCHAR(60) NULL,
    ADD UNIQUE KEY `uq_dagarage_owner_location_slot` (`citizenid`, `dagarage_location`, `dagarage_slot`),
    ADD UNIQUE KEY `uq_dagarage_society_location_slot` (`dagarage_society`, `dagarage_location`, `dagarage_slot`);
