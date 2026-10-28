<?php

$vendorDir = dirname(__DIR__);
$baseDir = dirname($vendorDir);

return array(
    'Acme\\Pkg\\' => array($vendorDir . '/acme/pkg/src'),
    'App\\' => array($baseDir . '/app'),
);
